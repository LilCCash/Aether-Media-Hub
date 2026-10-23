package app.aether.core.net

/** Every failure the addon engine can surface to the UI. [message] is user-facing Italian text. */
sealed class AddonError(override val message: String, val isTransient: Boolean = false) : Exception(message) {
    class InvalidUrl(detail: String) : AddonError("URL non valido: $detail")
    class Blocked(val reason: BlockReason) : AddonError(reason.message)
    object Timeout : AddonError("L'addon non ha risposto in tempo.", isTransient = true)
    object Offline : AddonError("Nessuna connessione a Internet.", isTransient = true)
    class Http(val status: Int) : AddonError("L'addon ha risposto con errore HTTP $status.", isTransient = status >= 500 || status == 429)
    class ResponseTooLarge(limit: Int) : AddonError("Risposta troppo grande (limite ${limit / 1024} KiB).")
    object TlsFailure : AddonError("Certificato TLS non valido o connessione sicura non riuscita.")
    class Unreachable(host: String) : AddonError("Impossibile raggiungere «$host».", isTransient = true)
    class InvalidManifest(detail: String) : AddonError(detail)
    class MalformedResponse(detail: String) : AddonError("Risposta dell'addon non valida: $detail")
    class Duplicate(existingName: String) : AddonError("L'addon «$existingName» è già installato.")
    object ConfigurationRequired : AddonError("Questo addon richiede una configurazione prima dell'installazione.")
    object NotFound : AddonError("Contenuto non trovato presso l'addon (404).")
    class Unsupported(detail: String) : AddonError(detail)

    sealed class BlockReason(val message: String) {
        class Scheme(scheme: String) : BlockReason("Schema «$scheme» non consentito (sono ammessi solo http e https).")
        object CredentialsInUrl : BlockReason("L'URL contiene nome utente/password incorporati: non consentito.")
        class PrivateAddress(host: String) :
            BlockReason("«$host» è un indirizzo di rete locale o privato. Abilita «Rete locale» nelle impostazioni per usarlo.")
        object Loopback : BlockReason("L'indirizzo punta a questo stesso dispositivo (localhost) e non è utilizzabile.")
        class LocalHostname(host: String) :
            BlockReason("«$host» è un nome host locale. Abilita «Rete locale» nelle impostazioni per usarlo.")
        object EmptyHost : BlockReason("L'URL non contiene un host valido.")
        object TooLong : BlockReason("L'URL è troppo lungo.")
    }

    companion object {
        /** Maps anything thrown by the transport to an [AddonError]. */
        fun from(error: Throwable): AddonError = when (error) {
            is AddonError -> error
            is java.net.SocketTimeoutException, is java.io.InterruptedIOException -> Timeout
            is javax.net.ssl.SSLException -> TlsFailure
            is java.net.UnknownHostException -> Unreachable(error.message?.substringBefore(':')?.take(60) ?: "host")
            is java.net.ConnectException, is java.net.NoRouteToHostException -> Unreachable(error.message?.take(60) ?: "host")
            is java.io.IOException -> Unreachable(error.message?.take(60) ?: "rete")
            else -> Unreachable(error.message?.take(60) ?: "errore")
        }
    }
}
