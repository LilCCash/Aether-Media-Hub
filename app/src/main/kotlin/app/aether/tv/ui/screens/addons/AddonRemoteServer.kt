package app.aether.tv.ui.screens.addons

import fi.iki.elonen.NanoHTTPD
import app.aether.core.net.AddonError
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.SecureRandom
import kotlinx.coroutines.runBlocking

/**
 * Short-lived, token-protected LAN form so addon URLs can be pasted from a phone instead of typed with a TV remote.
 * It binds on all interfaces only while the Addons screen is open and stops when that screen leaves.
 */
class AddonRemoteServer(private val engine: app.aether.core.AetherEngine) : NanoHTTPD("0.0.0.0", PORT) {
    private val registry get() = engine.registry
    private val token = ByteArray(18).also { SecureRandom().nextBytes(it) }
        .joinToString("") { "%02x".format(it) }

    val localUrl: String? get() = localIpv4()?.let { "http://$it:$PORT/?token=$token" }

    override fun serve(session: IHTTPSession): Response {
        val supplied = session.parameters["token"]?.firstOrNull().orEmpty()
        if (!constantTimeEquals(token, supplied)) return html(Response.Status.FORBIDDEN, page("Accesso negato", "Token non valido. Torna alla TV e riapri la pagina di collegamento."))
        if (session.method == Method.GET) return html(Response.Status.OK, formPage(session.parameters["ok"]?.firstOrNull(), session.parameters["keys"]?.firstOrNull(), session.parameters["restored"]?.firstOrNull()))
        if (session.method == Method.POST && session.uri == "/keys") return saveKeys(session)
        if (session.method == Method.POST && session.uri == "/restore") return restore(session)
        if (session.method != Method.POST || session.uri != "/install") {
            return html(Response.Status.NOT_FOUND, page("Pagina non trovata", "Torna alla pagina principale."))
        }
        return try {
            val files = HashMap<String, String>()
            session.parseBody(files)
            val url = session.parameters["url"]?.firstOrNull()?.trim().orEmpty()
            if (url.isBlank()) return html(Response.Status.BAD_REQUEST, page("Manca il link", "Inserisci l'indirizzo completo del manifest."))
            val addon = runBlocking { registry.install(url) }
            val redirect = newFixedLengthResponse(Response.Status.REDIRECT_SEE_OTHER, "text/plain", "")
            redirect.addHeader("Location", "/?token=$token&ok=" + java.net.URLEncoder.encode(addon.displayName, "UTF-8"))
            redirect
        } catch (error: Throwable) {
            val message = AddonError.from(error).message
            html(Response.Status.BAD_REQUEST, page("Installazione non riuscita", escape(message) + "<p>Controlla il link e riprova.</p>"))
        }
    }

    private fun restore(session: IHTTPSession): Response {
        val files = HashMap<String, String>()
        session.parseBody(files)
        val path = files["backup"] ?: return html(Response.Status.BAD_REQUEST, page("Nessun file", "Scegli un file di backup (.json)."))
        val message = try {
            val text = java.io.File(path).readText()
            val contents = app.aether.core.library.BackupCodec.decode(text)
            val replace = session.parameters["mode"]?.firstOrNull() == "replace"
            runBlocking { engine.restoreBackup(contents, replace) }
        } catch (error: app.aether.core.library.BackupError) {
            return html(Response.Status.BAD_REQUEST, page("Backup non valido", "Il file non è un backup di Aether. Scegli un file creato da Aether per Android TV o per iPhone."))
        } catch (error: Throwable) {
            return html(Response.Status.BAD_REQUEST, page("Ripristino non riuscito", escape(error.message ?: "errore")))
        }
        val redirect = newFixedLengthResponse(Response.Status.REDIRECT_SEE_OTHER, "text/plain", "")
        redirect.addHeader("Location", "/?token=$token&restored=" + java.net.URLEncoder.encode(message, "UTF-8"))
        return redirect
    }

    private fun saveKeys(session: IHTTPSession): Response {
        session.parseBody(HashMap())
        fun field(name: String) = session.parameters[name]?.firstOrNull()?.trim().orEmpty()
        val saved = mutableListOf<String>()
        field("tmdb").takeIf { it.isNotEmpty() }?.let { engine.secrets.put(app.aether.core.metadata.MetadataEnrichment.TMDbKey, it); saved += "TMDB" }
        field("tvdb").takeIf { it.isNotEmpty() }?.let { engine.secrets.put(app.aether.core.metadata.MetadataEnrichment.TVDbKey, it); saved += "TheTVDB" }
        field("pin").takeIf { it.isNotEmpty() }?.let { engine.secrets.put(app.aether.core.metadata.MetadataEnrichment.TVDbPin, it) }
        field("torbox").takeIf { it.isNotEmpty() }?.let { value ->
            try { engine.torBox.saveKey(value); saved += "TorBox" } catch (_: IllegalArgumentException) { return html(Response.Status.BAD_REQUEST, page("Chiave TorBox non valida", "Niente spazi o caratteri speciali.")) }
        }
        engine.metadata.clearCaches()
        val redirect = newFixedLengthResponse(Response.Status.REDIRECT_SEE_OTHER, "text/plain", "")
        redirect.addHeader("Location", "/?token=$token&keys=" + java.net.URLEncoder.encode(saved.joinToString(", ").ifEmpty { "nessuna" }, "UTF-8"))
        return redirect
    }

    private fun formPage(installed: String?, keys: String?, restored: String?): String = """
        <!doctype html><html lang="it"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta charset="utf-8"><title>Aether · Aggiungi addon</title>
        <style>body{font:16px system-ui;background:#101018;color:#f5f3ff;margin:0;padding:24px}main{max-width:520px;margin:auto}input,button{box-sizing:border-box;width:100%;font:inherit;padding:14px;margin:8px 0;border-radius:12px;border:1px solid #555;background:#20202c;color:white}button{background:#8b7cff;border:0;font-weight:700}p{color:#c7c3d8;line-height:1.5}</style>
        <main><h1>Aether · Aggiungi addon</h1>${installed?.let { "<p style=\"background:#1f3d2b;color:#9df0b8;padding:12px;border-radius:12px\">✅ «${escape(it)}» installato sulla TV. Puoi aggiungerne un altro.</p>" }.orEmpty()}<p>Incolla qui il link del manifest copiato dal telefono. L'addon verrà installato sulla TV collegata alla stessa rete Wi-Fi.</p>
        <form method="post" action="/install?token=$token"><input type="hidden" name="token" value="$token">
        <label for="url">Link manifest</label><input id="url" name="url" type="url" required autofocus value="" placeholder="https://…/manifest.json">
        <button type="submit">Verifica e installa</button></form><h2>Chiavi dei servizi</h2>${keys?.let { "<p style=\"background:#1f3d2b;color:#9df0b8;padding:12px;border-radius:12px\">✅ Salvate: ${escape(it)}.</p>" }.orEmpty()}<p>Facoltative. Lascia vuoto quello che non vuoi cambiare. Vengono salvate cifrate sulla TV.</p>
        <form method="post" action="/keys?token=$token"><label>Chiave o token TMDB</label><input name="tmdb" autocomplete="off"><label>Chiave API TheTVDB</label><input name="tvdb" autocomplete="off"><label>PIN TheTVDB (solo abbonati)</label><input name="pin" autocomplete="off"><label>Chiave TorBox</label><input name="torbox" autocomplete="off"><button type="submit">Salva le chiavi</button></form>
        <h2>Ripristina un backup</h2>${restored?.let { "<p style=\"background:#1f3d2b;color:#9df0b8;padding:12px;border-radius:12px\">✅ ${escape(it)}</p>" }.orEmpty()}<p>Scegli sul telefono un file di backup (.json) creato da Aether: libreria, addon e chiavi (se incluse) tornano sulla TV.</p>
        <form method="post" action="/restore?token=$token" enctype="multipart/form-data"><input type="file" name="backup" accept=".json,application/json,text/plain" required>
        <label><input type="radio" name="mode" value="merge" checked style="width:auto"> Unisci a quello che ho</label><label><input type="radio" name="mode" value="replace" style="width:auto"> Sostituisci tutto</label><button type="submit">Ripristina</button></form>
        <p>Installa solo addon di cui ti fidi. Questo collegamento è temporaneo e si chiude quando esci dalla schermata Addon sulla TV.</p></main></html>
    """.trimIndent()

    private fun page(title: String, message: String) =
        """<!doctype html><html lang="it"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><body style="font:16px system-ui;background:#101018;color:#f5f3ff;padding:24px"><h1>$title</h1><p>$message</p><a style="color:#b5adff" href="/?token=$token">Torna indietro</a></body></html>"""

    private fun html(status: Response.IStatus, content: String): Response =
        newFixedLengthResponse(status, "text/html; charset=utf-8", content)

    private fun escape(value: String) = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&#39;")

    private fun constantTimeEquals(expected: String, actual: String): Boolean {
        if (expected.length != actual.length) return false
        var difference = 0
        for (i in expected.indices) difference = difference or (expected[i].code xor actual[i].code)
        return difference == 0
    }

    private fun localIpv4(): String? = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }
            ?.hostAddress
    } catch (_: Exception) { null }

    companion object { private const val PORT = 8765 }
}
