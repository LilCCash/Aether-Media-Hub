package app.aether.core.net

import java.net.URI

/**
 * Which addresses the app may contact. Addon URLs are given by the user, but a redirect or a response could point elsewhere:
 * loopback is never allowed, and private-network hosts only when the user turned on "Rete locale".
 */
data class NetworkPolicy(val allowLocalNetwork: Boolean = false) {
    /** The reason [url] is refused, or null when it may be contacted. */
    fun check(url: String): AddonError.BlockReason? {
        if (url.length > 4096) return AddonError.BlockReason.TooLong
        val uri = try {
            URI(url)
        } catch (_: Exception) {
            return AddonError.BlockReason.EmptyHost
        }
        val scheme = uri.scheme?.lowercase() ?: return AddonError.BlockReason.Scheme("")
        if (scheme != "http" && scheme != "https") return AddonError.BlockReason.Scheme(scheme)
        if (uri.rawUserInfo != null) return AddonError.BlockReason.CredentialsInUrl
        val host = uri.host?.lowercase()?.removePrefix("[")?.removeSuffix("]")
        if (host.isNullOrEmpty()) return AddonError.BlockReason.EmptyHost
        if (host == "localhost" || host.endsWith(".localhost")) return AddonError.BlockReason.Loopback
        val address = parseIpv4(host)
        if (address != null) {
            return when (classify(address)) {
                AddressClass.LOOPBACK, AddressClass.UNSPECIFIED -> AddonError.BlockReason.Loopback
                AddressClass.PRIVATE, AddressClass.LINK_LOCAL -> if (allowLocalNetwork) null else AddonError.BlockReason.PrivateAddress(host)
                else -> null
            }
        }
        if (host == "::1" || host == "0:0:0:0:0:0:0:1") return AddonError.BlockReason.Loopback
        if (host.contains(':')) {
            // IPv6 literal: unique-local (fc00::/7) and link-local (fe80::/10) count as private.
            val first = host.substringBefore(':').toIntOrNull(16) ?: 0
            if ((first and 0xfe00) == 0xfc00 || (first and 0xffc0) == 0xfe80) {
                return if (allowLocalNetwork) null else AddonError.BlockReason.PrivateAddress(host)
            }
            return null
        }
        if (host.endsWith(".local") || host.endsWith(".lan") || host.endsWith(".home") || host.endsWith(".internal") || !host.contains('.')) {
            return if (allowLocalNetwork) null else AddonError.BlockReason.LocalHostname(host)
        }
        return null
    }

    enum class AddressClass { PUBLIC, LOOPBACK, PRIVATE, LINK_LOCAL, UNSPECIFIED }

    companion object {
        fun parseIpv4(text: String): IntArray? {
            val parts = text.split('.')
            if (parts.size != 4) return null
            val bytes = IntArray(4)
            for ((index, part) in parts.withIndex()) {
                if (part.isEmpty() || part.length > 3 || !part.all { it in '0'..'9' }) return null
                val value = part.toInt()
                if (value > 255) return null
                bytes[index] = value
            }
            return bytes
        }

        fun classify(b: IntArray): AddressClass = when {
            b[0] == 0 -> AddressClass.UNSPECIFIED
            b[0] == 127 -> AddressClass.LOOPBACK
            b[0] == 10 -> AddressClass.PRIVATE
            b[0] == 172 && b[1] in 16..31 -> AddressClass.PRIVATE
            b[0] == 192 && b[1] == 168 -> AddressClass.PRIVATE
            b[0] == 100 && b[1] in 64..127 -> AddressClass.PRIVATE
            b[0] == 169 && b[1] == 254 -> AddressClass.LINK_LOCAL
            else -> AddressClass.PUBLIC
        }
    }
}
