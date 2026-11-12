package app.aether.tv.updates

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import app.aether.tv.BuildConfig
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request

/** What the release on GitHub announces (written by the APK workflow next to the APK). */
@Serializable
data class UpdateInfo(
    val versionCode: Int,
    val versionName: String,
    val apkUrl: String,
    val sha256: String,
    val size: Long = 0,
    val notes: String = "",
    val publishedAt: String = "",
)

/**
 * «Cerca aggiornamenti»: reads the small `update.json` of the app's rolling GitHub release, downloads the newer APK (checking its
 * SHA-256) and hands it to the system installer, which asks the viewer to confirm. An update installs over the app only when it is
 * signed with the same key; the workflow signs every build with the repository key for this reason.
 */
object AppUpdater {
    sealed class State {
        object Idle : State()
        object Checking : State()
        data class UpToDate(val checkedAt: Long) : State()
        data class Available(val info: UpdateInfo) : State()
        data class Downloading(val info: UpdateInfo, val fraction: Double?) : State()
        data class Installing(val info: UpdateInfo) : State()
        /** The TV asks to allow «Installa app sconosciute» for Aether first. */
        data class NeedsPermission(val info: UpdateInfo) : State()
        data class Failed(val message: String) : State()
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> get() = _state

    private val client by lazy { OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).followRedirects(true).build() }
    private val json = Json { ignoreUnknownKeys = true }

    val currentVersion: String get() = "${BuildConfig.VERSION_NAME} (build ${BuildConfig.VERSION_CODE})"

    /** Asks GitHub whether a newer build exists. [quiet] keeps errors out of the state (the check at start-up). */
    suspend fun check(quiet: Boolean = false): UpdateInfo? {
        if (BuildConfig.UPDATE_URL.isBlank()) return null
        _state.value = State.Checking
        return try {
            val info = withContext(Dispatchers.IO) {
                client.newCall(Request.Builder().url(BuildConfig.UPDATE_URL).header("Cache-Control", "no-cache").build()).execute().use { response ->
                    if (response.code == 404) return@withContext null
                    if (!response.isSuccessful) throw IllegalStateException("GitHub ha risposto ${response.code}")
                    json.decodeFromString(UpdateInfo.serializer(), response.body.string())
                }
            }
            if (info != null && info.versionCode > BuildConfig.VERSION_CODE && info.apkUrl.startsWith("https://")) {
                _state.value = State.Available(info); info
            } else {
                _state.value = State.UpToDate(System.currentTimeMillis()); null
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            _state.value = if (quiet) State.Idle else State.Failed("Non riesco a controllare gli aggiornamenti: ${e.message ?: "errore di rete"}")
            null
        }
    }

    /** Downloads and installs [info]. Returns when the system installer has been handed the APK (or something failed). */
    suspend fun install(context: Context, info: UpdateInfo) {
        if (Build.VERSION.SDK_INT >= 26 && !context.packageManager.canRequestPackageInstalls()) {
            _state.value = State.NeedsPermission(info)
            return
        }
        try {
            _state.value = State.Downloading(info, null)
            val file = withContext(Dispatchers.IO) { download(context, info) }
            _state.value = State.Installing(info)
            withContext(Dispatchers.IO) { commit(context, file) }
        } catch (e: CancellationException) {
            _state.value = State.Available(info)
            throw e
        } catch (e: Throwable) {
            _state.value = State.Failed("Aggiornamento non riuscito: ${e.message ?: "errore"}")
        }
    }

    /** Opens the system page where the viewer allows Aether to install apps (Android 8+). */
    fun openInstallPermission(context: Context): Boolean = runCatching {
        context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }.isSuccess

    private fun download(context: Context, info: UpdateInfo): File {
        val dir = File(context.cacheDir, "updates").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val target = File(dir, "aether-${info.versionCode}.apk")
        val digest = MessageDigest.getInstance("SHA-256")
        client.newCall(Request.Builder().url(info.apkUrl).build()).execute().use { response ->
            if (!response.isSuccessful) throw IllegalStateException("download non riuscito (${response.code})")
            val body = response.body
            val total = body.contentLength().takeIf { it > 0 } ?: info.size.takeIf { it > 0 }
            var read = 0L
            var lastReport = 0L
            target.outputStream().use { out ->
                body.byteStream().use { input ->
                    val buffer = ByteArray(128 * 1024)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        digest.update(buffer, 0, n)
                        read += n
                        val now = System.currentTimeMillis()
                        if (now - lastReport > 300) {
                            lastReport = now
                            _state.update { State.Downloading(info, total?.let { read.toDouble() / it }) }
                        }
                    }
                }
            }
        }
        val sha = digest.digest().joinToString("") { "%02x".format(it) }
        if (info.sha256.isNotBlank() && !sha.equals(info.sha256, ignoreCase = true)) {
            target.delete()
            throw IllegalStateException("il file scaricato non corrisponde (controllo SHA-256)")
        }
        return target
    }

    private fun commit(context: Context, apk: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("aether.apk", 0, apk.length()).use { out ->
                apk.inputStream().use { it.copyTo(out, 128 * 1024) }
                session.fsync(out)
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val intent = Intent(context, InstallResultReceiver::class.java).setPackage(context.packageName)
            session.commit(PendingIntent.getBroadcast(context, id, intent, flags).intentSender)
        }
    }

    internal fun report(message: String?) {
        _state.value = if (message == null) State.Idle else State.Failed(message)
    }
}

/** The installer's answer: asks the viewer to confirm, or reports why it did not install. */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java) else intent.getParcelableExtra(Intent.EXTRA_INTENT))
                confirm?.let { runCatching { context.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } }
            }
            PackageInstaller.STATUS_SUCCESS -> AppUpdater.report(null)
            else -> {
                val detail = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty()
                AppUpdater.report(
                    when (status) {
                        PackageInstaller.STATUS_FAILURE_ABORTED -> "Installazione annullata."
                        PackageInstaller.STATUS_FAILURE_CONFLICT, PackageInstaller.STATUS_FAILURE_INCOMPATIBLE ->
                            "L'aggiornamento è firmato con una chiave diversa da quella installata: disinstalla questa versione una volta, poi gli aggiornamenti si installeranno da soli."
                        PackageInstaller.STATUS_FAILURE_STORAGE -> "Spazio insufficiente sulla TV."
                        else -> "Installazione non riuscita${if (detail.isNotBlank()) ": $detail" else "."}"
                    },
                )
            }
        }
    }
}
