package app.aether.tv.nav

import android.net.Uri

object Routes {
    const val HOME = "home"
    const val DISCOVER = "discover"
    const val SEARCH = "search"
    const val RECOMMEND = "recommend"
    const val LIBRARY = "library"
    const val LIVE = "live"
    const val TRAKT = "trakt"
    const val ADDONS = "addons"
    const val SETTINGS = "settings"
    const val DETAIL = "detail/{type}/{id}"
    const val PERSON = "person/{id}/{name}"
    const val STREAMS = "streams"
    const val PLAYER = "player"
    const val UNIVERSE = "universe/{id}"
    const val PROFILE = "profile"
    const val TASTE = "taste"
    const val DIAGNOSTICS = "diagnostics"
    const val CLOUD = "cloud"

    fun universe(id: String) = "universe/${Uri.encode(id.ifBlank { "-" })}"

    fun person(id: Int, name: String) = "person/$id/${Uri.encode(name.ifBlank { "Persona" })}"
    fun detail(type: String, id: String) = "detail/${Uri.encode(type.ifBlank { "movie" })}/${Uri.encode(id.ifBlank { "-" })}"

    /** The screens the side menu leads to; every other screen is reached from one of them. */
    val topLevel = listOf(HOME, DISCOVER, SEARCH, RECOMMEND, LIVE, LIBRARY, ADDONS, SETTINGS, PROFILE)
}
