package app.aether.tv.ui.screens.profile

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.aether.core.addons.RequestPlanner
import app.aether.core.model.ExtraValue
import app.aether.core.model.MetaItem
import app.aether.core.profile.TasteVerdict
import app.aether.core.profile.TasteVote
import app.aether.tv.aether
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.LoadingState
import app.aether.tv.ui.components.RemoteImage
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAccent
import kotlinx.coroutines.CancellationException

/**
 * The taste game: one film at a time, big. ▶ (or «Mi piace») = I like it, ◀ = I don't, ▲ = pass. Films come from the addons'
 * catalogs of the genres the viewer likes; the votes feed the profile and the recommendations.
 */
@Composable
fun TasteGameScreen(onOpenDetail: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val engine = LocalContext.current.aether
    val deck = remember { mutableStateListOf<MetaItem>() }
    var loading by remember { mutableStateOf(true) }
    var count by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) {
        val profile = engine.settings.value.value.profile
        val seen = engine.library.history(3000).map { it.metaId }.toSet() + profile.votes.map { it.id } + profile.skipped
        val genres = profile.topGenres().map { it.cinemeta }
        val refs = RequestPlanner.feedCatalogs(engine.addons.handles(), type = "movie")
        val found = ArrayList<MetaItem>()
        for (ref in refs.take(6)) {
            val options = ref.catalog.genreOptions
            val wanted = genres.filter { g -> options.any { it.equals(g, true) } }.take(3)
            val extras: List<List<ExtraValue>> = if (wanted.isEmpty()) listOf(emptyList()) else wanted.map { listOf(ExtraValue("genre", options.first { o -> o.equals(it, true) })) }
            for (extra in extras) {
                try { found += engine.addons.catalog(ref, extra).items } catch (e: Throwable) { if (e is CancellationException) throw e }
            }
            if (found.size > 120) break
        }
        // Alternated by genre so the pile does not show ten comedies in a row.
        deck += found.distinctBy { it.id }.filter { it.id !in seen && it.poster != null }.shuffled(java.util.Random(System.currentTimeMillis() / 86_400_000)).take(80)
        loading = false
    }
    val current = deck.firstOrNull()
    fun verdict(v: TasteVerdict?) {
        val m = deck.removeFirstOrNull() ?: return
        count++
        engine.settings.update { s ->
            s.copy(profile = if (v == null) s.profile.skip(m.id) else s.profile.vote(TasteVote(m.id, m.type, m.name, m.poster, m.releaseInfo, m.genres, v)))
        }
    }
    when {
        loading -> LoadingState("Preparo i film…", modifier.fillMaxSize())
        current == null -> EmptyState(
            if (count > 0) "Per oggi è tutto" else "Nessun film da proporti",
            if (count > 0) "Hai votato $count titoli: i consigli di «Per te» ne terranno conto." else "Servono un addon con cataloghi di film (Cinemeta va benissimo) e la rete.",
            modifier.fillMaxSize(),
        )
        else -> {
            val like = remember { FocusRequester() }
            Row(
                modifier.fillMaxSize().padding(horizontal = AetherDimens.ScreenHorizontal, vertical = 24.dp)
                    .onPreviewKeyEvent { e ->
                        if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                        when (e.key) {
                            Key.MediaFastForward -> { verdict(TasteVerdict.LIKE); true }
                            Key.MediaRewind -> { verdict(TasteVerdict.DISLIKE); true }
                            else -> false
                        }
                    },
                horizontalArrangement = Arrangement.spacedBy(48.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                androidx.compose.animation.AnimatedContent(current, label = "card") { m ->
                    app.aether.tv.ui.components.FocusSurface({ onOpenDetail(m) }, Modifier.width(300.dp).aspectRatio(0.675f), glow = true, focusScale = 1.03f) {
                        RemoteImage(m.poster, m.name, Modifier.fillMaxSize())
                    }
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text("GIOCO DEI GUSTI · ${count + 1}", style = MaterialTheme.typography.labelLarge, color = LocalAccent.current)
                    Text(current.name, style = MaterialTheme.typography.displaySmall, color = AetherColors.OnBackground, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(listOfNotNull(current.releaseInfo, current.genres.take(3).joinToString(" · ").ifEmpty { null }, current.imdbRating?.let { "★ $it" }).joinToString("   ·   "), style = MaterialTheme.typography.titleSmall, color = AetherColors.OnSurfaceMuted)
                    current.description?.let { Text(it, style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground.copy(alpha = 0.85f), maxLines = 5, overflow = TextOverflow.Ellipsis) }
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.padding(top = 10.dp)) {
                        TvButton("Non fa per me", { verdict(TasteVerdict.DISLIKE) }, icon = Icons.Filled.Close, testTag = "taste.no")
                        TvButton("Mi piace", { verdict(TasteVerdict.LIKE) }, icon = Icons.Filled.Favorite, primary = true, focusRequester = like, testTag = "taste.yes")
                        TvButton("Salta", { verdict(null) }, icon = Icons.Filled.SkipNext, testTag = "taste.skip")
                    }
                    Text("OK sulla locandina apre la scheda del film.", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint)
                }
            }
            RequestFocusOnce(like)
        }
    }
}
