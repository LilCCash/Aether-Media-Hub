package app.aether.tv.remote

import app.aether.core.AetherEngine
import app.aether.core.addons.AddonDebridScope
import app.aether.core.debrid.DebridService
import app.aether.core.debrid.RealDebridClient
import app.aether.core.debrid.TorBoxClient
import app.aether.core.metadata.MdbListClient
import app.aether.core.metadata.MetadataEnrichment
import app.aether.core.net.AddonError
import app.aether.core.remote.PhoneLinkSession
import app.aether.core.remote.PhoneLinkSession.Access
import fi.iki.elonen.NanoHTTPD
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.URLEncoder
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.runBlocking

/**
 * «Configura dal telefono»: a page on the local network, opened by scanning the QR code on the TV, to paste what is slow to type
 * with a remote: addon links, the keys of every service (TMDB, TheTVDB, fanart.tv, MDBList, TorBox, Real-Debrid), Live TV playlists
 * and guide, a backup file; and to manage the installed addons.
 *
 * Safety: a random port and a random 256-bit token for each session; the first phone must be approved on the TV and then it is the
 * only one served; the session ends after 10 idle minutes (30 at most) or when the screen on the TV closes; a few wrong tokens end
 * it at once. The page never shows a saved key, only whether it is set. Requests from another site are refused (Origin check), the
 * answers are not cached and carry no referrer. The traffic is plain HTTP inside the home network: the page says so.
 */
class PhoneConfigServer(private val engine: AetherEngine, val session: PhoneLinkSession = PhoneLinkSession()) : NanoHTTPD("0.0.0.0", 0) {
    data class Event(val text: String, val at: Long = System.currentTimeMillis())

    private val _pending = MutableStateFlow<String?>(null)
    /** A phone waiting for the viewer's approval on the TV (its address). */
    val pending: StateFlow<String?> get() = _pending
    private val _events = MutableStateFlow<List<Event>>(emptyList())
    /** What the phone did, for the list on the TV (never with a key or a link). */
    val events: StateFlow<List<Event>> get() = _events

    val address: String? get() = localIpv4()?.let { "http://$it:$listeningPort/s/${session.token}/" }

    fun answer(allow: Boolean) {
        session.answer(allow)
        _pending.value = null
        record(if (allow) "Telefono collegato." else "Collegamento rifiutato.")
    }

    override fun stop() {
        session.close()
        super.stop()
    }

    private fun record(text: String) = _events.update { (it + Event(text)).takeLast(12) }

    override fun serve(http: IHTTPSession): Response {
        val parts = http.uri.trim('/').split('/')
        if (parts.size < 2 || parts[0] != "s") return page(Response.Status.NOT_FOUND, "Pagina non trovata", "Inquadra di nuovo il codice QR sulla TV.")
        val client = http.remoteIpAddress ?: "?"
        // Whatever the answer, a POST body is read to the end first: a browser whose upload is cut short shows «connessione persa»
        // instead of the page that explains why.
        fun refuse(response: Response): Response { if (http.method == Method.POST) drain(http); return response }
        when (session.check(parts[1], client)) {
            Access.EXPIRED -> return refuse(page(Response.Status.GONE, "Collegamento scaduto", "Sulla TV apri di nuovo «Configura dal telefono» e inquadra il nuovo codice."))
            Access.BAD_TOKEN, Access.DENIED -> return refuse(page(Response.Status.FORBIDDEN, "Accesso negato", "Questo telefono non è autorizzato. Sulla TV apri di nuovo «Configura dal telefono»."))
            Access.NEEDS_APPROVAL, Access.WAITING -> {
                _pending.value = client
                return refuse(waitingPage())
            }
            Access.ALLOWED -> Unit
        }
        val action = parts.drop(2).joinToString("/")
        if (http.method == Method.GET) return if (action.isEmpty()) home(http.parameters["msg"]?.firstOrNull()) else redirect(null)
        if (http.method != Method.POST) return page(Response.Status.METHOD_NOT_ALLOWED, "Richiesta non valida", "")
        // Another site's form is refused. «null» (a privacy setting of the browser) and no Origin at all are accepted: the secret
        // token in the address and the approved phone already protect the page.
        val origin = http.headers["origin"]
        val host = http.headers["host"]
        if (origin != null && origin != "null" && host != null && origin != "http://$host") {
            return refuse(page(Response.Status.FORBIDDEN, "Richiesta rifiutata", "La richiesta non arriva da questa pagina."))
        }
        val length = http.headers["content-length"]?.toLongOrNull() ?: 0
        if (length > MAX_BODY) return refuse(page(Response.Status.PAYLOAD_TOO_LARGE, "File troppo grande", "Il limite è ${MAX_BODY / 1_048_576} MB."))
        val files = HashMap<String, String>()
        return try {
            http.parseBody(files)
            fun field(name: String) = http.parameters[name]?.firstOrNull()?.trim().orEmpty()
            val message = runBlocking { perform(action, ::field, files) }
            redirect(message)
        } catch (error: Throwable) {
            redirect("⚠️ " + (error as? IllegalArgumentException)?.message.orEmpty().ifEmpty { AddonError.from(error).message })
        }
    }

    private suspend fun perform(action: String, field: (String) -> String, files: Map<String, String>): String {
        val segments = action.split('/')
        return when (segments.first()) {
            "install" -> {
                val url = field("url").ifEmpty { throw IllegalArgumentException("Inserisci il link del manifest.") }
                val addon = engine.registry.install(url)
                record("Addon installato: ${addon.displayName}")
                "✅ «${addon.displayName}» installato."
            }
            "addon" -> {
                val id = segments.getOrNull(1) ?: throw IllegalArgumentException("Addon non trovato.")
                val addon = engine.registry.all().firstOrNull { it.id == id } ?: throw IllegalArgumentException("Addon non trovato.")
                when (segments.getOrNull(2)) {
                    "toggle" -> engine.registry.setEnabled(!addon.isEnabled, id)
                    "up" -> engine.registry.move(id, -1)
                    "down" -> engine.registry.move(id, 1)
                    "remove" -> { engine.registry.uninstall(id); record("Addon rimosso: ${addon.displayName}") }
                    "scope" -> engine.registry.setDebridScope(AddonDebridScope.entries.firstOrNull { it.name == field("scope") } ?: AddonDebridScope.BOTH, id)
                    else -> throw IllegalArgumentException("Azione sconosciuta.")
                }
                "✅ «${addon.displayName}» aggiornato."
            }
            "keys" -> {
                val saved = ArrayList<String>()
                fun put(name: String, secret: String, title: String) { field(name).takeIf { it.isNotEmpty() }?.let { engine.secrets.put(secret, it); saved += title } }
                put("tmdb", MetadataEnrichment.TMDbKey, "TMDB")
                put("tvdb", MetadataEnrichment.TVDbKey, "TheTVDB")
                put("tvdbPin", MetadataEnrichment.TVDbPin, "PIN TheTVDB")
                put("fanart", MetadataEnrichment.FanartKey, "fanart.tv")
                put("mdblist", MdbListClient.KEY_SECRET, "MDBList")
                field("torbox").takeIf { it.isNotEmpty() }?.let { engine.torBox.saveKey(it); saved += "TorBox" }
                field("realdebrid").takeIf { it.isNotEmpty() }?.let { engine.realDebrid.saveKey(it); saved += "Real-Debrid" }
                DebridService.entries.firstOrNull { it.name == field("debrid") }?.let { choice ->
                    engine.settings.update { it.copy(network = it.network.copy(debridService = choice)) }
                    saved += "servizio debrid: ${choice.title}"
                }
                engine.metadata.clearCaches()
                if (saved.isEmpty()) "Nessuna chiave cambiata." else "✅ Salvate: ${saved.joinToString(", ")}.".also { record("Chiavi salvate: ${saved.joinToString(", ")}") }
            }
            "forget" -> {
                val (secret, title) = KEYS[segments.getOrNull(1)] ?: throw IllegalArgumentException("Chiave sconosciuta.")
                engine.secrets.remove(secret)
                engine.metadata.clearCaches()
                record("Chiave rimossa: $title")
                "✅ $title rimossa."
            }
            "playlist" -> {
                val problem = engine.liveTv.addPlaylist(field("name"), field("url"))
                if (problem != null) "⚠️ $problem" else "✅ Playlist aggiunta.".also { record("Playlist aggiunta"); engine.liveTv.refreshGuide() }
            }
            "guide" -> {
                engine.settings.update { it.copy(liveTv = it.liveTv.copy(guideUrl = field("url"))) }
                engine.liveTv.refreshGuide(force = true)
                engine.liveTv.state.value.guideMessage?.let { "⚠️ $it" } ?: "✅ Guida aggiornata.".also { record("Guida TV aggiornata") }
            }
            "restore" -> {
                val path = files["backup"] ?: throw IllegalArgumentException("Scegli un file di backup (.json).")
                val text = File(path).readText()
                val contents = try { app.aether.core.library.BackupCodec.decode(text) } catch (_: app.aether.core.library.BackupError) {
                    throw IllegalArgumentException("Il file non è un backup di Aether.")
                }
                val message = engine.restoreBackup(contents, field("mode") == "replace")
                record("Backup ripristinato")
                "✅ $message"
            }
            "close" -> { session.close(); record("Collegamento chiuso dal telefono."); "Collegamento chiuso." }
            else -> throw IllegalArgumentException("Azione sconosciuta.")
        }
    }

    // MARK: Pages

    private fun base() = "/s/${session.token}/"

    private fun redirect(message: String?): Response {
        val response = newFixedLengthResponse(Response.Status.REDIRECT_SEE_OTHER, "text/plain", "")
        response.addHeader("Location", base() + (message?.let { "?msg=" + URLEncoder.encode(it, "UTF-8") } ?: ""))
        return secure(response)
    }

    private fun waitingPage(): Response = html(Response.Status.OK, """
        <meta http-equiv="refresh" content="2"><h1>Conferma sulla TV</h1>
        <p>Sulla TV è comparsa una richiesta: scegli <b>Consenti</b> con il telecomando. Questa pagina si aggiorna da sola.</p>
    """)

    private fun home(message: String?): Response = runBlocking {
        val addons = engine.registry.all()
        val s = engine.settings.value.value
        fun keyRow(id: String, label: String, set: Boolean, type: String = "password") = """
            <label>$label ${if (set) "<span class=ok>impostata</span> <button class=link formaction='${base()}forget/$id' formnovalidate>rimuovi</button>" else "<span class=no>non impostata</span>"}</label>
            <input name="$id" type="$type" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="${if (set) "lascia vuoto per non cambiarla" else ""}">
        """
        val addonRows = addons.joinToString("") { a ->
            val id = esc(a.id)
            """<div class=card><b>${esc(a.displayName)}</b> <small>${esc(a.host)}${if (!a.isEnabled) " · disattivato" else ""}</small>
            <form method=post class=row>
              <button formaction="${base()}addon/$id/toggle">${if (a.isEnabled) "Disattiva" else "Attiva"}</button>
              <button formaction="${base()}addon/$id/up">Su</button><button formaction="${base()}addon/$id/down">Giù</button>
              <button formaction="${base()}addon/$id/remove" class=danger onclick="return confirm('Rimuovere ${esc(a.displayName)}?')">Rimuovi</button>
            </form>
            <form method=post action="${base()}addon/$id/scope" class=row><select name=scope>${AddonDebridScope.entries.joinToString("") { "<option value=${it.name}${if (it == a.debridScope) " selected" else ""}>Debrid: ${it.title}</option>" }}</select><button>Salva</button></form></div>"""
        }
        html(Response.Status.OK, """
            <h1>Aether · Configura la TV</h1>
            ${message?.let { "<p class=msg>${esc(it)}</p>" }.orEmpty()}
            <p class=small>Collegamento temporaneo e solo nella tua rete di casa (non cifrato): usalo sulla tua Wi-Fi. Scade da solo.</p>
            <h2>Aggiungi un addon</h2>
            <form method=post action="${base()}install"><input name=url type=url required placeholder="https://…/manifest.json" autocomplete=off><button class=primary>Verifica e installa</button></form>
            <h2>Addon installati (${addons.size})</h2>$addonRows
            <h2>Chiavi dei servizi</h2>
            <form method=post action="${base()}keys">
            <label>Servizio debrid in uso</label><select name=debrid>${DebridService.entries.joinToString("") { "<option value=${it.name}${if (it == s.network.debridService) " selected" else ""}>${it.title}</option>" }}</select>
            ${keyRow("torbox", "Chiave TorBox", engine.torBox.isConfigured)}
            ${keyRow("realdebrid", "Token Real-Debrid", engine.realDebrid.isConfigured)}
            ${keyRow("tmdb", "Chiave o token TMDB", isSet(MetadataEnrichment.TMDbKey))}
            ${keyRow("tvdb", "Chiave TheTVDB", isSet(MetadataEnrichment.TVDbKey))}
            ${keyRow("tvdbPin", "PIN TheTVDB (solo abbonati)", isSet(MetadataEnrichment.TVDbPin))}
            ${keyRow("fanart", "Chiave fanart.tv (loghi)", isSet(MetadataEnrichment.FanartKey))}
            ${keyRow("mdblist", "Chiave MDBList (voti)", isSet(MdbListClient.KEY_SECRET))}
            <button class=primary>Salva le chiavi</button></form>
            <h2>TV in diretta</h2>
            <form method=post action="${base()}playlist"><label>Nome della playlist</label><input name=name autocomplete=off><label>Indirizzo M3U</label><input name=url type=url required autocomplete=off placeholder="https://…/lista.m3u"><button>Aggiungi la playlist</button></form>
            <form method=post action="${base()}guide"><label>Guida XMLTV (vuoto: automatica)</label><input name=url type=url autocomplete=off value="${esc(s.liveTv.guideUrl)}"><button>Salva la guida</button></form>
            <h2>Ripristina un backup</h2>
            <form method=post action="${base()}restore" enctype="multipart/form-data"><input type=file name=backup accept=".json,application/json,text/plain" required>
            <label class=inline><input type=radio name=mode value=merge checked> Unisci a quello che c'è</label><label class=inline><input type=radio name=mode value=replace> Sostituisci tutto</label><button>Ripristina</button></form>
            <form method=post action="${base()}close"><button class=danger>Chiudi il collegamento</button></form>
        """)
    }

    /** Reads and discards what is left of a request body (bounded by the size limit). */
    private fun drain(http: IHTTPSession) {
        val length = http.headers["content-length"]?.toLongOrNull() ?: return
        runCatching {
            val buffer = ByteArray(64 * 1024)
            var left = minOf(length, MAX_BODY + 1)
            while (left > 0) { val n = http.inputStream.read(buffer, 0, minOf(buffer.size.toLong(), left).toInt()); if (n < 0) break; left -= n }
        }
    }

    private fun isSet(secret: String) = !engine.secrets.get(secret).isNullOrBlank()

    private fun page(status: Response.IStatus, title: String, message: String) = html(status, "<h1>${esc(title)}</h1><p>${esc(message)}</p>")

    private fun html(status: Response.IStatus, body: String): Response = secure(newFixedLengthResponse(status, "text/html; charset=utf-8", """
        <!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Aether</title>
        <style>body{font:16px system-ui;background:#0b0a12;color:#f3f1fb;margin:0;padding:20px}main{max-width:560px;margin:auto}h2{margin-top:28px}
        input,select,button{box-sizing:border-box;width:100%;font:inherit;padding:13px;margin:6px 0;border-radius:12px;border:1px solid #3a3550;background:#1e1b2e;color:#f3f1fb}
        button{background:#2a2640;border:0;font-weight:600}.primary{background:#8b7cff;color:#0b0a12}.danger{background:#5a2330}.link{width:auto;padding:2px 8px;margin:0 4px;font-size:13px}
        .row{display:flex;gap:8px}.row button,.row select{flex:1}.card{background:#15131f;border-radius:14px;padding:12px;margin:10px 0}small,.small{color:#b9b4ce}
        .msg{background:#1f3d2b;color:#9df0b8;padding:12px;border-radius:12px}.ok{color:#3ddc97;font-size:13px}.no{color:#857f9c;font-size:13px}label{display:block;margin-top:10px}.inline input{width:auto}</style>
        </head><body><main>$body</main></body></html>
    """.trimIndent()))

    private fun secure(response: Response): Response = response.apply {
        // Every answer closes its connection. With keep-alive Safari reuses an idle connection the TV has meanwhile closed (choosing
        // a file in Files takes longer than the socket timeout) and a form sent on it fails with «connessione persa»: a POST is
        // never retried. A fresh connection for each request costs nothing on the home network.
        closeConnection(true)
        addHeader("Cache-Control", "no-store")
        addHeader("Referrer-Policy", "same-origin")
        addHeader("X-Frame-Options", "DENY")
        addHeader("X-Content-Type-Options", "nosniff")
        addHeader("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; script-src 'unsafe-inline'")
    }

    private fun esc(value: String) = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&#39;")

    private fun localIpv4(): String? = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && !it.isVirtual }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull { it.isSiteLocalAddress }
            ?.hostAddress
    } catch (_: Exception) { null }

    companion object {
        /** How long a phone may take to send a request it started (a slow Wi-Fi upload included). */
        const val SOCKET_TIMEOUT_MS = 60_000
        /** Backups with a long history reach tens of MB (the iPhone one included). */
        private const val MAX_BODY = 96L * 1024 * 1024
        private val KEYS = mapOf(
            "torbox" to (TorBoxClient.KEY_SECRET to "Chiave TorBox"),
            "realdebrid" to (RealDebridClient.KEY_SECRET to "Token Real-Debrid"),
            "tmdb" to (MetadataEnrichment.TMDbKey to "Chiave TMDB"),
            "tvdb" to (MetadataEnrichment.TVDbKey to "Chiave TheTVDB"),
            "tvdbPin" to (MetadataEnrichment.TVDbPin to "PIN TheTVDB"),
            "fanart" to (MetadataEnrichment.FanartKey to "Chiave fanart.tv"),
            "mdblist" to (MdbListClient.KEY_SECRET to "Chiave MDBList"),
        )
    }
}
