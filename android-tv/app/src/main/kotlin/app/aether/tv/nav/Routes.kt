package app.aether.tv.nav

import android.net.Uri

object Routes {
    const val HOME = "home"
    const val DISCOVER = "discover"
    const val SEARCH = "search"
    const val RECOMMEND = "recommend"
    const val LIBRARY = "library"
    const val ADDONS = "addons"
    const val SETTINGS = "settings"
    const val DETAIL = "detail/{type}/{id}"
    const val PERSON = "person/{id}/{name}"
    const val STREAMS = "streams"
    const val PLAYER = "player"

    fun person(id: Int, name: String) = "person/$id/${Uri.encode(name)}"
    fun detail(type: String, id: String) = "detail/${Uri.encode(type)}/${Uri.encode(id)}"

    /** The screens the side menu leads to; every other screen is reached from one of them. */
    val topLevel = listOf(HOME, DISCOVER, SEARCH, RECOMMEND, LIBRARY, ADDONS, SETTINGS)
}
