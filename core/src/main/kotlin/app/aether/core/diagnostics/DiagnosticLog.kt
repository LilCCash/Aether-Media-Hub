package app.aether.core.diagnostics

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Removes secrets from anything that may be logged or exported. Addon URLs routinely carry API keys in the path or the query, so
 * addresses are reduced to `scheme://host/…`; key=value pairs, bearer tokens, e-mail addresses and long tokens are masked.
 */
object Redactor {
    private val url = Regex("""(?i)\b(https?|stremio|ftp|rtmp)://(\[[^\]]+\]|[^/\s:?#"'<>]+)(:\d+)?[^\s"'<>]*""")
    private val pair = Regex("""(?i)\b(api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|token|secret|password|passwd|pwd|authorization|bearer|auth|session|cookie|key)\b(["']?)\s*[=:]\s*(?:"[^"]*"|'[^']*'|["']?[^\s&,;"']+)""")
    private val bearer = Regex("""(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=\-]+""")
    private val email = Regex("""(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}""")
    private val longToken = Regex("""\b[A-Za-z0-9_\-]{32,}\b""")

    fun redact(text: String): String = text
        .replace(url, "$1://$2$3/…")
        .replace(bearer, "$1 «redatto»")
        .replace(pair, "$1$2=«redatto»")
        .replace(email, "«email»")
        .replace(longToken, "«token»")
}

enum class LogLevel(val label: String) { DEBUG("DEBUG"), INFO("INFO"), WARNING("WARN"), ERROR("ERROR") }

data class LogEntry(val timeMillis: Long, val level: LogLevel, val category: String, val message: String)

/**
 * The diagnostic log of the app: a ring of redacted lines in memory, kept across restarts in a small file. Nothing is sent anywhere;
 * the viewer can read it in the settings and send it to the phone on purpose.
 */
class DiagnosticLog(private val file: java.io.File? = null, private val capacity: Int = 600, private val now: () -> Long = System::currentTimeMillis) {
    private val buffer = ArrayDeque<LogEntry>()
    @Volatile var enabled: Boolean = true
        set(value) { field = value; if (!value) clear() }
    @Volatile var verbose: Boolean = false
    /** Also hands every kept line (already redacted) to the system log. */
    @Volatile var mirror: ((LogLevel, String, String) -> Unit)? = null

    init { load() }

    fun log(level: LogLevel, category: String, message: String) {
        if (!enabled || (level == LogLevel.DEBUG && !verbose)) return
        val entry = LogEntry(now(), level, category, Redactor.redact(message).take(600))
        mirror?.invoke(level, category, entry.message)
        synchronized(buffer) {
            buffer.addLast(entry)
            while (buffer.size > capacity) buffer.removeFirst()
        }
        scheduleSave()
    }

    fun info(category: String, message: String) = log(LogLevel.INFO, category, message)
    fun warn(category: String, message: String) = log(LogLevel.WARNING, category, message)
    fun error(category: String, message: String, error: Throwable? = null) =
        log(LogLevel.ERROR, category, if (error == null) message else "$message: ${error::class.simpleName}: ${error.message.orEmpty()}")
    fun debug(category: String, message: String) = log(LogLevel.DEBUG, category, message)

    fun entries(): List<LogEntry> = synchronized(buffer) { buffer.toList() }

    fun clear() {
        synchronized(buffer) { buffer.clear() }
        runCatching { file?.delete() }
    }

    /** Plain text, already redacted when written and redacted again on the way out. */
    fun exportText(header: List<String> = emptyList()): String {
        val format = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.ROOT)
        val lines = ArrayList(header)
        lines += "— registro diagnostico di Aether (senza indirizzi completi né credenziali) —"
        for (e in entries()) lines += Redactor.redact("${format.format(Date(e.timeMillis))} [${e.level.label}] ${e.category}: ${e.message}")
        return lines.joinToString("\n")
    }

    // A save at most every couple of seconds, on a background thread: logging never waits for the disk.
    @Volatile private var savePending = false
    private fun scheduleSave() {
        val target = file ?: return
        if (savePending) return
        savePending = true
        Thread {
            try { Thread.sleep(2000) } catch (_: InterruptedException) {}
            savePending = false
            runCatching {
                target.parentFile?.mkdirs()
                val text = entries().joinToString("\n") { "${it.timeMillis}\t${it.level.name}\t${it.category.replace('\t', ' ')}\t${it.message.replace('\n', ' ').replace('\t', ' ')}" }
                val tmp = java.io.File(target.path + ".tmp")
                tmp.writeText(text)
                tmp.renameTo(target)
            }
        }.apply { isDaemon = true; name = "aether-log" }.start()
    }

    private fun load() {
        val source = file?.takeIf { it.exists() } ?: return
        runCatching {
            source.readLines().takeLast(capacity).forEach { line ->
                val p = line.split('\t', limit = 4)
                if (p.size == 4) {
                    val level = runCatching { LogLevel.valueOf(p[1]) }.getOrNull() ?: return@forEach
                    buffer.addLast(LogEntry(p[0].toLongOrNull() ?: 0, level, p[2], p[3]))
                }
            }
        }
    }
}
