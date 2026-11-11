package app.aether.core.util

import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneOffset

/** Release dates in the shapes addons send them: ISO date-time, a plain date, or an epoch. */
object AddonDate {
    fun parse(text: String?): Instant? {
        val raw = text?.trim().orEmpty()
        if (raw.isEmpty()) return null
        try {
            return Instant.parse(raw)
        } catch (_: Exception) {
        }
        try {
            return OffsetDateTime.parse(raw).toInstant()
        } catch (_: Exception) {
        }
        try {
            return LocalDate.parse(raw.take(10)).atStartOfDay().toInstant(ZoneOffset.UTC)
        } catch (_: Exception) {
        }
        return null
    }

    fun format(instant: Instant): String = instant.toString()
}

fun Instant.year(): Int = atOffset(ZoneOffset.UTC).year
