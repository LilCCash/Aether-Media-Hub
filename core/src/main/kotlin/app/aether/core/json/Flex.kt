package app.aether.core.json

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Lenient access to addon JSON. Addons in the wild send numbers as strings, strings as numbers, `null` for "absent" and single
 * values where a list is expected; the Stremio clients tolerate all of it, so this does too. (Port of `FlexDecoding` in the iOS core.)
 */
object Flex {
    val json: Json = Json {
        ignoreUnknownKeys = true
        // Not lenient: "<html>" must be refused as "not JSON", not read as a bare string.
        encodeDefaults = true
        explicitNulls = false
        coerceInputValues = true
    }

    fun parse(text: String): JsonElement? {
        // An HTML error page or a stray word is "not JSON", whatever the parser would make of it.
        val first = text.trimStart().firstOrNull() ?: return null
        if (first !in "{[\"-0123456789tfn") return null
        return try {
            json.parseToJsonElement(text)
        } catch (_: Exception) {
            null
        }
    }
}

fun JsonObject.flexString(key: String): String? {
    val value = this[key] ?: return null
    if (value is JsonNull) return null
    if (value is JsonPrimitive) {
        val text = value.content
        return if (value.isString || text.isNotEmpty()) text else null
    }
    return null
}

fun JsonObject.flexInt(key: String): Int? {
    val value = this[key] as? JsonPrimitive ?: return null
    if (value is JsonNull) return null
    value.content.toIntOrNull()?.let { return it }
    return value.content.toDoubleOrNull()?.takeIf { it.isFinite() }?.toInt()
}

fun JsonObject.flexLong(key: String): Long? {
    val value = this[key] as? JsonPrimitive ?: return null
    if (value is JsonNull) return null
    value.content.toLongOrNull()?.let { return it }
    return value.content.toDoubleOrNull()?.takeIf { it.isFinite() }?.toLong()
}

fun JsonObject.flexDouble(key: String): Double? {
    val value = this[key] as? JsonPrimitive ?: return null
    if (value is JsonNull) return null
    return value.content.replace(',', '.').toDoubleOrNull()
}

fun JsonObject.flexBool(key: String): Boolean? {
    val value = this[key] as? JsonPrimitive ?: return null
    if (value is JsonNull) return null
    return when (value.content.lowercase()) {
        "true", "1", "yes" -> true
        "false", "0", "no" -> false
        else -> null
    }
}

/** A list of strings; a single string counts as a list of one; anything else is empty. */
fun JsonObject.stringList(key: String): List<String> {
    val value = this[key] ?: return emptyList()
    return when (value) {
        is JsonArray -> value.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p !is JsonNull }?.content }.filter { it.isNotEmpty() }
        is JsonPrimitive -> if (value is JsonNull || value.content.isEmpty()) emptyList() else listOf(value.content)
        else -> emptyList()
    }
}

fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

fun JsonObject.has(key: String): Boolean = containsKey(key)

/** Decodes every element of an array with [transform], dropping the ones it rejects (a bad entry must not lose the others). */
inline fun <T> JsonObject.lossyList(key: String, transform: (JsonObject) -> T?): List<T> {
    val array = this[key] as? JsonArray ?: return emptyList()
    val result = ArrayList<T>(array.size)
    for (element in array) {
        val item = element as? JsonObject ?: continue
        val decoded = try {
            transform(item)
        } catch (_: Exception) {
            null
        }
        if (decoded != null) result.add(decoded)
    }
    return result
}
