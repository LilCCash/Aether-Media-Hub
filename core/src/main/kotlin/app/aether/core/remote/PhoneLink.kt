package app.aether.core.remote

import java.security.MessageDigest
import java.security.SecureRandom

/**
 * The rules of one «configure from the phone» session, kept apart from the HTTP server so they can be tested:
 * - a random 256-bit token in the address (the QR code), compared in constant time;
 * - a short life (10 minutes by default, renewed while the phone is in use, never beyond 30 minutes in all);
 * - the first phone that opens the page must be approved on the TV; then only that phone (its address) is served;
 * - a few wrong tokens close the session at once.
 * Nothing here ever logs or returns a secret.
 */
class PhoneLinkSession(
    private val now: () -> Long = System::currentTimeMillis,
    val idleMillis: Long = 10 * 60_000L,
    val maxMillis: Long = 30 * 60_000L,
    private val maxBadTokens: Int = 5,
    random: SecureRandom = SecureRandom(),
) {
    enum class Access { ALLOWED, NEEDS_APPROVAL, WAITING, DENIED, BAD_TOKEN, EXPIRED }

    val token: String = ByteArray(32).also { random.nextBytes(it) }.joinToString("") { "%02x".format(it) }
    private val startedAt = now()
    private var lastUse = startedAt
    private var badTokens = 0
    private var closed = false

    /** The phone that asked to connect and is waiting for the TV's answer. */
    @Volatile var pendingClient: String? = null
        private set
    @Volatile var approvedClient: String? = null
        private set
    private val denied = HashSet<String>()

    val isClosed: Boolean @Synchronized get() = closed || isExpired()

    @Synchronized
    fun expiresAt(): Long = minOf(lastUse + idleMillis, startedAt + maxMillis)

    private fun isExpired() = now() >= expiresAt()

    /** Decides what a request from [client] (its IP address) carrying [suppliedToken] may do. */
    @Synchronized
    fun check(suppliedToken: String?, client: String): Access {
        if (closed || isExpired()) return Access.EXPIRED
        if (!constantTimeEquals(token, suppliedToken.orEmpty())) {
            badTokens++
            if (badTokens >= maxBadTokens) closed = true
            return Access.BAD_TOKEN
        }
        if (client in denied) return Access.DENIED
        val approved = approvedClient
        if (approved != null) {
            if (approved != client) return Access.DENIED
            lastUse = now()
            return Access.ALLOWED
        }
        return when (pendingClient) {
            null -> { pendingClient = client; Access.NEEDS_APPROVAL }
            client -> Access.WAITING
            else -> Access.DENIED
        }
    }

    /** The viewer's answer on the TV. */
    @Synchronized
    fun answer(allow: Boolean) {
        val client = pendingClient ?: return
        pendingClient = null
        if (allow) { approvedClient = client; lastUse = now() } else denied.add(client)
    }

    @Synchronized
    fun close() { closed = true }

    companion object {
        fun constantTimeEquals(expected: String, actual: String): Boolean =
            MessageDigest.isEqual(expected.toByteArray(Charsets.UTF_8), actual.toByteArray(Charsets.UTF_8))
    }
}
