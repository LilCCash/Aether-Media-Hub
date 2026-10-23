package app.aether.tv.nav

import androidx.activity.compose.BackHandler
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import app.aether.core.model.MetaItem
import app.aether.core.model.Video
import app.aether.tv.Session
import app.aether.tv.StreamRequest
import app.aether.tv.ui.components.SideNav
import app.aether.tv.ui.screens.addons.AddonsScreen
import app.aether.tv.ui.screens.detail.DetailScreen
import app.aether.tv.ui.screens.detail.StreamsScreen
import app.aether.tv.ui.screens.discover.DiscoverScreen
import app.aether.tv.ui.screens.home.HomeScreen
import app.aether.tv.ui.screens.library.LibraryScreen
import app.aether.tv.ui.screens.player.PlayerScreen
import app.aether.tv.ui.screens.search.SearchScreen
import app.aether.tv.ui.screens.settings.AboutScreen
import app.aether.tv.ui.screens.settings.SettingsScreen
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens

private const val ABOUT = "about"

/** The screens of the app and the way between them. Back from a section goes to the Home; from the Home it leaves the app. */
@Composable
fun AetherNav(initialAddonInput: String?, modifier: Modifier = Modifier) {
    val nav: NavHostController = rememberNavController()
    val entry by nav.currentBackStackEntryAsState()
    val route = entry?.destination?.route
    val showRail = route in Routes.topLevel

    fun openDetail(meta: MetaItem) { Session.putPreview(meta); nav.navigate(Routes.detail(meta.type, meta.id)) }
    fun openStreams(meta: MetaItem, video: Video?, resumeAt: Double?) {
        Session.putPreview(meta)
        Session.streamRequest = StreamRequest(meta, video, resumeAt)
        nav.navigate(Routes.STREAMS)
    }
    fun goTop(target: String) {
        nav.navigate(target) {
            popUpTo(Routes.HOME) { saveState = false }
            launchSingleTop = true
        }
    }

    // A link opened while the app is running leads to the addons screen, where the viewer is asked before anything is installed.
    androidx.compose.runtime.LaunchedEffect(initialAddonInput) {
        if (initialAddonInput != null && route != Routes.ADDONS && route != null) goTop(Routes.ADDONS)
    }

    // Back from any other section leads to the Home first, like on every TV app.
    BackHandler(enabled = showRail && route != Routes.HOME) { goTop(Routes.HOME) }

    Box(modifier.fillMaxSize()) {
        NavHost(
            navController = nav,
            startDestination = if (initialAddonInput != null) Routes.ADDONS else Routes.HOME,
            modifier = Modifier.fillMaxSize().padding(start = if (showRail) AetherDimens.RailCollapsed else 0.dp),
            enterTransition = { fadeIn(tween(220)) },
            exitTransition = { fadeOut(tween(160)) },
            popEnterTransition = { fadeIn(tween(220)) },
            popExitTransition = { fadeOut(tween(160)) },
        ) {
            composable(Routes.HOME) {
                HomeScreen(onOpenDetail = ::openDetail, onPlay = ::openStreams, onOpenAddons = { input -> Session.pendingAddonInput = input; goTop(Routes.ADDONS) })
            }
            composable(Routes.DISCOVER) { DiscoverScreen(onOpenDetail = ::openDetail, onOpenAddons = { goTop(Routes.ADDONS) }) }
            composable(Routes.SEARCH) { SearchScreen(onOpenDetail = ::openDetail, onOpenAddons = { goTop(Routes.ADDONS) }) }
            composable(Routes.RECOMMEND) { app.aether.tv.ui.screens.recommend.RecommendScreen(onOpenDetail = ::openDetail, onOpenAddons = { goTop(Routes.ADDONS) }) }
            composable(Routes.LIBRARY) { LibraryScreen(onOpenDetail = ::openDetail, onOpenDiscover = { goTop(Routes.DISCOVER) }) }
            composable(Routes.ADDONS) { AddonsScreen(initialInput = initialAddonInput) }
            composable(Routes.SETTINGS) { SettingsScreen(onOpenAbout = { nav.navigate(ABOUT) }) }
            composable(ABOUT) { AboutScreen() }
            composable(
                Routes.DETAIL,
                arguments = listOf(navArgument("type") { type = NavType.StringType }, navArgument("id") { type = NavType.StringType }),
            ) { backStack ->
                val type = backStack.arguments?.getString("type").orEmpty()
                val id = backStack.arguments?.getString("id").orEmpty()
                DetailScreen(type, id, onPlay = ::openStreams, onOpenTitle = { t, i -> nav.navigate(Routes.detail(t, i)) })
            }
            composable(Routes.STREAMS) {
                StreamsScreen(onPlayerReady = { nav.navigate(Routes.PLAYER) }, onBack = { nav.popBackStack() })
            }
            composable(
                Routes.PLAYER,
                enterTransition = { fadeIn(tween(300)) },
                exitTransition = { fadeOut(tween(200)) },
            ) {
                PlayerScreen(
                    // Leaving the player returns to where the viewer chose what to watch, not to the list of sources.
                    onExit = { if (!nav.popBackStack(Routes.STREAMS, inclusive = true)) nav.popBackStack() },
                    onNextEpisode = { request ->
                        Session.streamRequest = request
                        nav.navigate(Routes.STREAMS) { popUpTo(Routes.STREAMS) { inclusive = true } }
                    },
                )
            }
        }
        if (showRail) SideNav(current = route.orEmpty(), onSelect = ::goTop, modifier = Modifier.align(androidx.compose.ui.Alignment.CenterStart))
    }
}
