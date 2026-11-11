package app.aether.core.playback

/** How far one press of Left/Right jumps in the player. */
object SeekSteps {
    /** The usual step, then more the longer the button is held (the key repeat count grows while it is down). */
    fun stepSeconds(repeatCount: Int, baseSeconds: Int): Int = when {
        repeatCount > 30 -> baseSeconds * 6
        repeatCount > 15 -> baseSeconds * 3
        repeatCount > 5 -> baseSeconds * 2
        else -> baseSeconds
    }

    /** Where a seek ends up: never before the start, never past the end (when the length is known). */
    fun target(currentMs: Long, deltaMs: Long, durationMs: Long?): Long {
        val limit = durationMs?.takeIf { it > 0 } ?: Long.MAX_VALUE
        return (currentMs + deltaMs).coerceIn(0, limit)
    }
}
