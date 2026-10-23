package app.aether.core.addons

import app.aether.core.model.ExtraValue
import app.aether.core.model.ResourcePath
import app.aether.core.net.AddonError
import java.net.URI
import java.net.URLEncoder
import java.security.MessageDigest

/** Parsing / normalisation of the strings users paste or deep links deliver. */
object AddonUrl {
    const val MANIFEST_SUFFIX = "/manifest.json"

    /**
     * Turns user input into a canonical manifest URL. Accepts `https://host/path/manifest.json`, `stremio://…` (→ https),
     * the addon's `/configure` page, and a bare `host/path`. Rejects other schemes, embedded credentials and missing hosts.
     * The query is kept (many addons keep their configuration there); the fragment is dropped.
     */
    fun parseInstallInput(raw: String): String {
        var text = raw.trim()
        if (text.startsWith("<") && text.endsWith(">")) text = text.substring(1, text.length - 1)
        text = text.trim('"', '\'', '`')
        if (text.isEmpty()) throw AddonError.InvalidUrl("l'indirizzo è vuoto")
        if (text.length > 4096) throw AddonError.Blocked(AddonError.BlockReason.TooLong)

        val lower = text.lowercase()
        if (lower.startsWith("stremio:///")) throw AddonError.InvalidUrl("questo link Stremio non installa un addon")
        text = when {
            lower.startsWith("stremio://") -> "https://" + text.substring("stremio://".length)
            lower.startsWith("stremio:") -> throw AddonError.InvalidUrl("questo link Stremio non installa un addon")
            !lower.contains("://") -> {
                // "javascript:…" is a scheme, "host:7000/path" is a bare host with a port.
                val colon = text.indexOf(':')
                if (colon > 0) {
                    val name = text.substring(0, colon)
                    val rest = text.substring(colon + 1)
                    val looksLikePort = rest.firstOrNull()?.isDigit() == true
                    val validScheme = name.first().isLetter() && name.all { it.isLetterOrDigit() || it in "+.-" }
                    if (validScheme && !looksLikePort) throw AddonError.Blocked(AddonError.BlockReason.Scheme(name.lowercase()))
                }
                "https://$text"
            }
            else -> text
        }

        val uri = try {
            URI(text.replace(" ", "%20"))
        } catch (_: Exception) {
            throw AddonError.InvalidUrl("formato non riconosciuto")
        }
        val scheme = uri.scheme?.lowercase() ?: throw AddonError.InvalidUrl("manca lo schema")
        if (scheme != "http" && scheme != "https") throw AddonError.Blocked(AddonError.BlockReason.Scheme(scheme))
        if (uri.rawUserInfo != null) throw AddonError.Blocked(AddonError.BlockReason.CredentialsInUrl)
        val host = uri.host?.takeIf { it.isNotEmpty() } ?: throw AddonError.Blocked(AddonError.BlockReason.EmptyHost)

        var path = uri.rawPath.orEmpty().ifEmpty { "/" }
        val lowerPath = path.lowercase()
        path = when {
            lowerPath.endsWith(MANIFEST_SUFFIX) -> path
            lowerPath.endsWith("/configure") -> path.dropLast("/configure".length) + MANIFEST_SUFFIX
            lowerPath.endsWith(".json") -> throw AddonError.InvalidUrl("l'URL deve terminare con /manifest.json")
            else -> (if (path.endsWith("/")) path else "$path/") + "manifest.json"
        }
        val port = if (uri.port >= 0) ":${uri.port}" else ""
        val query = uri.rawQuery?.let { "?$it" }.orEmpty()
        return "$scheme://${host.lowercase()}$port$path$query"
    }

    /** Identifies the addon endpoint independent of host case, default ports and fragment; used for duplicate detection. */
    fun canonicalKey(url: String): String {
        val uri = try {
            URI(url)
        } catch (_: Exception) {
            return url
        }
        val scheme = uri.scheme?.lowercase().orEmpty()
        val defaultPort = (scheme == "https" && uri.port == 443) || (scheme == "http" && uri.port == 80)
        val port = if (uri.port >= 0 && !defaultPort) ":${uri.port}" else ""
        val query = uri.rawQuery?.let { "?$it" }.orEmpty()
        return "$scheme://${uri.host?.lowercase().orEmpty()}$port${uri.rawPath.orEmpty()}$query"
    }

    /** Non-secret label safe for UI and logs: `host[:port]`. Addon URLs often embed API keys in the path or query. */
    fun displayHost(url: String): String {
        val uri = try {
            URI(url)
        } catch (_: Exception) {
            return "—"
        }
        val host = uri.host ?: return "—"
        return if (uri.port >= 0) "$host:${uri.port}" else host
    }

    /** Links handled on launch: `stremio://…/manifest.json`, `aether://addon?url=…`. */
    fun installUrlFromDeepLink(link: String): String? {
        val lower = link.lowercase()
        return try {
            when {
                lower.startsWith("stremio://") -> parseInstallInput(link)
                lower.startsWith("aether://addon") || lower.startsWith("aether://install") -> {
                    val value = link.substringAfter("url=", "").substringBefore('&')
                    if (value.isEmpty()) null else parseInstallInput(java.net.URLDecoder.decode(value, "UTF-8"))
                }
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    fun sha256Hex(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
}

/** Builds `{base}/{resource}/{type}/{id}[/{extra}].json` exactly like stremio-core's HTTP transport. */
object ResourceUrlBuilder {
    /** Percent-encodes like JavaScript's `encodeURIComponent` (what addons expect): only letters, digits and `-_.!~*'()` stay. */
    fun encode(value: String): String =
        URLEncoder.encode(value, "UTF-8").replace("+", "%20").replace("%21", "!").replace("%27", "'").replace("%28", "(")
            .replace("%29", ")").replace("%7E", "~")

    fun encodeExtra(extra: List<ExtraValue>): String = extra.joinToString("&") { "${encode(it.name)}=${encode(it.value)}" }

    fun relativePath(path: ResourcePath): String {
        var result = "${encode(path.resource)}/${encode(path.type)}/${encode(path.id)}"
        if (path.extra.isNotEmpty()) result += "/" + encodeExtra(path.extra)
        return "$result.json"
    }

    /** Replaces the trailing `/manifest.json` of the transport URL; the manifest URL's query is preserved. */
    fun url(transport: String, path: ResourcePath): String? {
        val query = transport.substringAfter('?', "").let { if (it.isEmpty()) "" else "?$it" }
        val bare = transport.substringBefore('#').substringBefore('?')
        if (!bare.lowercase().endsWith(AddonUrl.MANIFEST_SUFFIX)) return null
        val base = bare.dropLast(AddonUrl.MANIFEST_SUFFIX.length)
        return "$base/${relativePath(path)}$query"
    }
}
