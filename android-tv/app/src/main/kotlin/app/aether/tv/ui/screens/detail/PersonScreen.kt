package app.aether.tv.ui.screens.detail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.aether.core.metadata.RichDetails
import app.aether.tv.aether
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.LoadingState
import app.aether.tv.ui.components.RemoteImage
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import kotlinx.coroutines.launch

/** What a person from the cast appeared in: each film or series with the character they played under the title. */
@Composable
fun PersonScreen(personId: Int, name: String, onOpenTitle: (String, String) -> Unit, modifier: Modifier = Modifier) {
    val engine = LocalContext.current.aether
    val scope = rememberCoroutineScope()
    val credits by produceState<List<RichDetails.Credit>?>(null, personId) { value = engine.metadata.personCredits(personId) }
    var opening by remember { mutableStateOf(false) }
    val first = remember { FocusRequester() }
    Column(modifier.fillMaxSize().padding(top = AetherDimens.ScreenVertical), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(name, style = MaterialTheme.typography.headlineLarge, color = AetherColors.OnBackground, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
        Text(if (opening) "Apro la scheda…" else "Film e serie in cui compare", style = MaterialTheme.typography.titleMedium, color = AetherColors.OnSurfaceMuted, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
        val list = credits
        when {
            list == null -> LoadingState("Cerco la filmografia…", Modifier.fillMaxSize())
            list.isEmpty() -> EmptyState("Nessun titolo", "TMDB non ha restituito titoli per questa persona (serve la chiave TMDB valida).", Modifier.fillMaxSize())
            else -> {
                LazyVerticalGrid(
                    GridCells.Adaptive(150.dp), Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 20.dp, bottom = 72.dp),
                    horizontalArrangement = Arrangement.spacedBy(AetherDimens.RowSpacing), verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    items(list.size, key = { "${list[it].tmdbId}-${list[it].isMovie}" }) { i ->
                        val credit = list[i]
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            FocusSurface(
                                {
                                    if (!opening) scope.launch {
                                        opening = true
                                        val imdb = engine.metadata.imdbIdFor(credit.tmdbId, credit.isMovie)
                                        opening = false
                                        if (imdb != null) onOpenTitle(if (credit.isMovie) "movie" else "series", imdb)
                                    }
                                },
                                Modifier.fillMaxWidth().aspectRatio(0.675f), focusRequester = if (i == 0) first else null,
                            ) { RemoteImage(credit.poster, credit.title, Modifier.fillMaxSize()) }
                            Text(credit.title, style = MaterialTheme.typography.labelMedium, color = AetherColors.OnBackground, maxLines = 2, minLines = 2, overflow = TextOverflow.Ellipsis)
                            Text(credit.character?.let { "nel ruolo di $it" } ?: " ", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted, maxLines = 2, minLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
                RequestFocusOnce(first, list.size)
            }
        }
    }
}
