package app.aether.tv.downloads

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.StatFs
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import app.aether.core.downloads.DownloadItem
import app.aether.core.downloads.DownloadState
import app.aether.tv.R
import app.aether.tv.aether
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Downloads one video in the background (a foreground job, so the TV does not stop it), resuming from where it stopped with an HTTP
 * Range request. The address is read from the encrypted store; nothing about it reaches a log or the notification.
 */
class DownloadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val store = applicationContext.aether.downloads
        val id = inputData.getString(KEY_ID) ?: return@withContext Result.failure()
        val item = store.item(id) ?: return@withContext Result.failure()
        val (url, headers) = store.source(id) ?: run {
            store.update(id) { it.copy(state = DownloadState.FAILED, error = "L'indirizzo della sorgente non c'è più: scarica di nuovo il titolo.") }
            return@withContext Result.failure()
        }
        runCatching { setForeground(foregroundInfo(item, null)) }
        val target = store.fileOf(item)
        val part = File(target.path + ".part")
        target.parentFile?.mkdirs()
        store.update(id) { it.copy(state = DownloadState.RUNNING, error = null) }
        try {
            var offset = if (part.exists()) part.length() else 0L
            val request = Request.Builder().url(url).apply {
                headers.forEach { (k, v) -> header(k, v) }
                if (offset > 0) header("Range", "bytes=$offset-")
            }.build()
            client.newCall(request).execute().use { response ->
                if (response.code == 416) { part.renameTo(target); store.finished(id, target.length()); return@withContext Result.success() }
                if (!response.isSuccessful) throw IOException("il server ha risposto ${response.code}")
                if (response.code != 206) offset = 0 // the server ignored the range: start again
                val body = response.body
                val length = body.contentLength().takeIf { it > 0 }
                val total = length?.let { it + offset }
                if (total != null) {
                    val free = StatFs(target.parentFile!!.path).availableBytes
                    if (total - offset > free) throw IOException("spazio insufficiente sulla TV (servono ${total / 1_048_576} MB)")
                }
                store.update(id) { it.copy(totalBytes = total, bytes = offset) }
                RandomAccessFile(part, "rw").use { out ->
                    out.setLength(offset)
                    out.seek(offset)
                    val buffer = ByteArray(256 * 1024)
                    var written = offset
                    var lastReport = 0L
                    body.byteStream().use { input ->
                        while (true) {
                            if (isStopped) throw CancellationException()
                            val read = input.read(buffer)
                            if (read < 0) break
                            out.write(buffer, 0, read)
                            written += read
                            val now = System.currentTimeMillis()
                            if (now - lastReport > 1000) {
                                lastReport = now
                                store.update(id) { it.copy(bytes = written) }
                                runCatching { setForeground(foregroundInfo(item, total?.let { written.toDouble() / it })) }
                            }
                        }
                    }
                }
            }
            if (!part.renameTo(target)) throw IOException("non riesco a salvare il file")
            store.finished(id, target.length())
            Result.success()
        } catch (e: CancellationException) {
            store.update(id) { if (it.state == DownloadState.RUNNING) it.copy(state = DownloadState.PAUSED, bytes = part.length()) else it }
            throw e
        } catch (e: Throwable) {
            val retry = e is IOException && runAttemptCount < 3 && e.message?.startsWith("spazio") != true
            store.update(id) { it.copy(state = if (retry) DownloadState.QUEUED else DownloadState.FAILED, bytes = part.length(), error = "Download non riuscito: ${e.message ?: "errore di rete"}") }
            if (retry) Result.retry() else Result.failure()
        }
    }

    private fun foregroundInfo(item: DownloadItem, fraction: Double?): ForegroundInfo {
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Download", NotificationManager.IMPORTANCE_LOW))
        }
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL)
            .setSmallIcon(R.drawable.ic_download)
            .setContentTitle("Download: ${item.label}")
            .setOngoing(true)
            .setProgress(100, ((fraction ?: 0.0) * 100).toInt(), fraction == null)
            .build()
        val notificationId = item.id.hashCode()
        return if (Build.VERSION.SDK_INT >= 29) ForegroundInfo(notificationId, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) else ForegroundInfo(notificationId, notification)
    }

    companion object {
        private const val KEY_ID = "id"
        private const val CHANNEL = "downloads"
        private val client by lazy { OkHttpClient.Builder().connectTimeout(20, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).build() }

        private fun name(id: String) = "download-$id"

        fun start(context: Context, id: String) {
            context.aether.downloads.update(id) { it.copy(state = DownloadState.QUEUED, error = null) }
            val request = OneTimeWorkRequestBuilder<DownloadWorker>()
                .setInputData(workDataOf(KEY_ID to id))
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .addTag("download")
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(name(id), ExistingWorkPolicy.KEEP, request)
        }

        fun pause(context: Context, id: String) {
            context.aether.downloads.update(id) { it.copy(state = DownloadState.PAUSED) }
            WorkManager.getInstance(context).cancelUniqueWork(name(id))
        }

        fun remove(context: Context, id: String) {
            WorkManager.getInstance(context).cancelUniqueWork(name(id))
            context.aether.downloads.remove(id)
        }
    }
}
