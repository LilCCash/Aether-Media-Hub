package app.aether.tv.ui.screens.addons

import fi.iki.elonen.NanoHTTPD
import app.aether.core.addons.AddonRegistry
import app.aether.core.net.AddonError
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.SecureRandom
import kotlinx.coroutines.runBlocking

/**
 * Short-lived, token-protected LAN form so addon URLs can be pasted from a phone instead of typed with a TV remote.
 * It binds on all interfaces only while the Addons screen is open and stops when that screen leaves.
 */
class AddonRemoteServer(private val registry: AddonRegistry) : NanoHTTPD("0.0.0.0", PORT) {
    private val token = ByteArray(18).also { SecureRandom().nextBytes(it) }
        .joinToString("") { "%02x".format(it) }

    val localUrl: String? get() = localIpv4()?.let { "http://$it:$PORT/?token=$token" }

    override fun serve(session: IHTTPSession): Response {
        val supplied = session.parameters["token"]?.firstOrNull().orEmpty()
        if (!constantTimeEquals(token, supplied)) return html(Response.Status.FORBIDDEN, page("Accesso negato", "Token non valido. Torna alla TV e riapri la pagina di collegamento."))
        if (session.method == Method.GET) return html(Response.Status.OK, formPage())
        if (session.method != Method.POST || session.uri != "/install") {
            return html(Response.Status.NOT_FOUND, page("Pagina non trovata", "Torna alla pagina principale."))
        }
        return try {
            val files = HashMap<String, String>()
            session.parseBody(files)
            val url = session.parameters["url"]?.firstOrNull()?.trim().orEmpty()
            if (url.isBlank()) return html(Response.Status.BAD_REQUEST, page("Manca il link", "Inserisci l'indirizzo completo del manifest."))
            val addon = runBlocking { registry.install(url) }
            html(Response.Status.OK, page("Addon installato", "«${escape(addon.displayName)}» è stato aggiunto alla TV. Puoi chiudere questa pagina e tornare ad Aether."))
        } catch (error: Throwable) {
            val message = AddonError.from(error).message
            html(Response.Status.BAD_REQUEST, page("Installazione non riuscita", escape(message) + "<p>Controlla il link e riprova.</p>"))
        }
    }

    private fun formPage(): String = """
        <!doctype html><html lang="it"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta charset="utf-8"><title>Aether · Aggiungi addon</title>
        <style>body{font:16px system-ui;background:#101018;color:#f5f3ff;margin:0;padding:24px}main{max-width:520px;margin:auto}input,button{box-sizing:border-box;width:100%;font:inherit;padding:14px;margin:8px 0;border-radius:12px;border:1px solid #555;background:#20202c;color:white}button{background:#8b7cff;border:0;font-weight:700}p{color:#c7c3d8;line-height:1.5}</style>
        <main><h1>Aether · Aggiungi addon</h1><p>Incolla qui il link del manifest copiato dal telefono. L'addon verrà installato sulla TV collegata alla stessa rete Wi-Fi.</p>
        <form method="post" action="/install?token=$token"><input type="hidden" name="token" value="$token">
        <label for="url">Link manifest</label><input id="url" name="url" type="url" required autofocus placeholder="https://…/manifest.json">
        <button type="submit">Verifica e installa</button></form><p>Installa solo addon di cui ti fidi. Questo collegamento è temporaneo e si chiude quando esci dalla schermata Addon sulla TV.</p></main></html>
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
