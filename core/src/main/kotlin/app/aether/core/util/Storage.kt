package app.aether.core.util

import java.io.File
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json

/** Where secrets live (addon URLs with keys, the TorBox key). The Android app backs it with the Keystore; tests use memory. */
interface SecretStore {
    fun get(key: String): String?
    fun put(key: String, value: String)
    fun remove(key: String)
}

class InMemorySecretStore : SecretStore {
    private val values = HashMap<String, String>()
    @Synchronized override fun get(key: String) = values[key]
    @Synchronized override fun put(key: String, value: String) { values[key] = value }
    @Synchronized override fun remove(key: String) { values.remove(key) }
}

/** One JSON document on disk, written atomically (temp file + rename) so a crash never leaves half a file. */
class JsonFileStore<T>(private val file: File, private val serializer: KSerializer<T>, private val json: Json = DEFAULT_JSON) {
    @Synchronized
    fun load(): T? {
        if (!file.exists()) return null
        return try {
            json.decodeFromString(serializer, file.readText())
        } catch (_: Exception) {
            // A damaged file is kept aside instead of being overwritten, so nothing is lost silently.
            runCatching { file.renameTo(File(file.parentFile, file.name + ".damaged")) }
            null
        }
    }

    @Synchronized
    fun save(value: T) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeText(json.encodeToString(serializer, value))
        if (!temp.renameTo(file)) {
            file.delete()
            temp.renameTo(file)
        }
    }

    @Synchronized
    fun delete() {
        file.delete()
    }

    companion object {
        val DEFAULT_JSON = Json { ignoreUnknownKeys = true; encodeDefaults = true; isLenient = true; coerceInputValues = true }
    }
}
