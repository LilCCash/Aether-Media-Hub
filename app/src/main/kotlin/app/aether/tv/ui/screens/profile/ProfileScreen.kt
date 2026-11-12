package app.aether.tv.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.aether.core.library.DiaryEntry
import app.aether.core.library.DiaryStats
import app.aether.core.library.RatingComparison
import app.aether.core.model.MetaItem
import app.aether.core.profile.ProfileAvatars
import app.aether.core.profile.ProfileGenre
import app.aether.tv.aether
import app.aether.tv.ui.components.AetherDialog
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.ProfileAvatarView
import app.aether.tv.ui.components.RemoteImage
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.SectionTitle
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.components.TvTextField
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAccent

/**
 * The profile, as on the iPhone: avatar and name, the genres the viewer likes, «Il mio universo del cinema» (the numbers of each
 * year), the viewer's ratings against the public's, the diary of what was watched, and the taste game.
 */
@OptIn(ExperimentalLayoutApi::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun ProfileScreen(onOpenDetail: (MetaItem) -> Unit, onOpenTaste: () -> Unit, onOpenTitle: (String, String) -> Unit, modifier: Modifier = Modifier) {
    val engine = LocalContext.current.aether
    val settings by engine.settings.value.collectAsStateWithLifecycle()
    val profile = settings.profile
    val revision by engine.library.revision.collectAsStateWithLifecycle()
    val diary = remember(revision) { engine.library.diary() }
    val years = remember(diary) { DiaryStats.years(diary) }
    var year by remember { mutableStateOf<Int?>(java.time.Year.now().value.takeIf { it in years } ?: years.firstOrNull()) }
    val stats = remember(diary, year) { DiaryStats.compute(diary, year) }
    val comparison = remember(diary) { RatingComparison.compute(diary) }
    var editing by remember { mutableStateOf(false) }
    var editingEntry by remember { mutableStateOf<DiaryEntry?>(null) }
    val first = remember { FocusRequester() }
    fun updateProfile(change: (app.aether.core.profile.ProfileSettings) -> app.aether.core.profile.ProfileSettings) = engine.settings.update { it.copy(profile = change(it.profile)) }

    androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides app.aether.tv.ui.theme.PivotScroll) {
    LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(top = AetherDimens.ScreenVertical, bottom = 72.dp), verticalArrangement = Arrangement.spacedBy(28.dp)) {
        item(key = "head") {
            Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), horizontalArrangement = Arrangement.spacedBy(28.dp), verticalAlignment = Alignment.CenterVertically) {
                ProfileAvatarView(profile.avatar, Modifier.size(128.dp))
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(profile.displayName ?: "Il tuo profilo", style = MaterialTheme.typography.displaySmall, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    val all = DiaryStats.compute(diary)
                    Text("${all.titles} titoli nel diario · ${all.hours} ore di visione · ${profile.likes.size} «mi piace»", style = MaterialTheme.typography.titleSmall, color = AetherColors.OnSurfaceMuted)
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(top = 6.dp)) {
                        TvButton("Modifica profilo", { editing = true }, primary = true, focusRequester = first, testTag = "profile.edit")
                        TvButton("Gioco dei gusti", onOpenTaste, testTag = "profile.taste")
                    }
                }
            }
            RequestFocusOnce(first)
        }
        item(key = "genres") {
            Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SectionTitle("Generi che ti piacciono")
                Text("Servono al gioco dei gusti e ai consigli di «Per te».", style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceMuted)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    ProfileGenre.entries.forEach { g ->
                        TvChip("${g.emoji} ${g.title}", g.name in profile.genres, { updateProfile { it.toggleGenre(g) } }, testTag = "profile.genre.${g.name}")
                    }
                }
            }
        }
        item(key = "universe") {
            Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SectionTitle("Il mio universo del cinema")
                if (diary.isEmpty()) Text("Non c'è ancora niente da contare: quello che guardi fino alla fine finisce nel diario da solo, e qui trovi i numeri.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
                else {
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        item { TvChip("Sempre", year == null, { year = null }) }
                        items(years.distinct()) { y -> TvChip("$y", year == y, { year = y }, testTag = "profile.year.$y") }
                    }
                    StatsCard(stats, year)
                }
            }
        }
        if (comparison.isNotEmpty()) item(key = "compare") {
            Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SectionTitle("I tuoi voti e quelli del pubblico")
                Text("Il tuo voto (stelle portate a 10) contro quello di IMDb: prima le differenze più grandi.", style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceMuted)
                LazyRow(horizontalArrangement = Arrangement.spacedBy(16.dp), contentPadding = PaddingValues(vertical = 8.dp)) {
                    items(comparison.take(20), key = { it.entry.id }) { c -> CompareCard(c) { onOpenTitle(c.entry.type, c.entry.metaId) } }
                }
            }
        }
        if (diary.isNotEmpty()) item(key = "diary") {
            app.aether.tv.ui.components.ContentRow("Diario", diary.take(60), { it.id }, rowId = "diary") { e, requester, onFocused ->
                DiaryCard(e, requester, onFocused) { editingEntry = e }
            }
        }
        if (profile.likes.isNotEmpty()) item(key = "likes") {
            app.aether.tv.ui.components.ContentRow("Ti piacciono", profile.likes.take(40), { it.id }, rowId = "likes") { v, requester, onFocused ->
                app.aether.tv.ui.components.PosterCard(MetaItem(v.id, v.type, v.name, v.poster, releaseInfo = v.year), { onOpenTitle(v.type, v.id) }, focusRequester = requester, onFocused = onFocused)
            }
        }
    }
    }

    if (editing) ProfileEditor(profile, { change -> updateProfile(change) }) { editing = false }
    editingEntry?.let { e -> DiaryEditor(e, onSave = { engine.library.saveDiary(it); editingEntry = null }, onDelete = { engine.library.removeDiary(e.id); editingEntry = null }, onOpen = { editingEntry = null; onOpenTitle(e.type, e.metaId) }) { editingEntry = null } }
}

@Composable
private fun StatsCard(stats: DiaryStats, year: Int?) {
    val accent = LocalAccent.current
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(Brush.linearGradient(listOf(accent.copy(alpha = 0.55f), Color(0xFF14141A)))).padding(28.dp),
        horizontalArrangement = Arrangement.spacedBy(36.dp),
    ) {
        Column(Modifier.width(240.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(if (year == null) "IN TOTALE" else "NEL $year", style = MaterialTheme.typography.labelLarge, color = Color.White.copy(alpha = 0.8f))
            Text("${stats.hours}", style = MaterialTheme.typography.displayLarge, color = Color.White)
            Text("ore davanti allo schermo", style = MaterialTheme.typography.titleSmall, color = Color.White.copy(alpha = 0.85f))
            Spacer(Modifier.height(10.dp))
            Text("${stats.films} film · ${stats.episodes} episodi", style = MaterialTheme.typography.titleMedium, color = Color.White)
            Text("${stats.rewatches} rivisti" + (stats.averageRating?.let { " · voto medio ${"%.1f".format(java.util.Locale.ITALY, it)}★" } ?: ""), style = MaterialTheme.typography.labelLarge, color = Color.White.copy(alpha = 0.8f))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Generi", style = MaterialTheme.typography.titleSmall, color = Color.White)
            val max = stats.topGenres.maxOfOrNull { it.second } ?: 1
            stats.topGenres.forEach { (name, count) ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(name, Modifier.width(120.dp), style = MaterialTheme.typography.labelLarge, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Box(Modifier.height(10.dp).fillMaxWidth(count.toFloat() / max * 0.8f).clip(RoundedCornerShape(5.dp)).background(Color.White.copy(alpha = 0.85f)))
                    Text("$count", style = MaterialTheme.typography.labelMedium, color = Color.White.copy(alpha = 0.8f))
                }
            }
            if (stats.topPeople.isNotEmpty()) {
                Text("Volti che ritornano", style = MaterialTheme.typography.titleSmall, color = Color.White, modifier = Modifier.padding(top = 6.dp))
                Text(stats.topPeople.joinToString(" · ") { "${it.first} (${it.second})" }, style = MaterialTheme.typography.labelLarge, color = Color.White.copy(alpha = 0.85f), maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        Column(Modifier.width(300.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Mese per mese", style = MaterialTheme.typography.titleSmall, color = Color.White)
            val max = (stats.perMonth.maxOrNull() ?: 0).coerceAtLeast(1)
            Row(Modifier.height(120.dp).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Bottom) {
                stats.perMonth.forEach { n ->
                    Box(Modifier.weight(1f).fillMaxHeight((n.toFloat() / max).coerceAtLeast(0.04f)).clip(RoundedCornerShape(4.dp)).background(if (n > 0) Color.White.copy(alpha = 0.9f) else Color.White.copy(alpha = 0.2f)))
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                listOf("G", "F", "M", "A", "M", "G", "L", "A", "S", "O", "N", "D").forEach { Text(it, style = MaterialTheme.typography.labelSmall, color = Color.White.copy(alpha = 0.7f)) }
            }
        }
    }
}

@Composable
private fun CompareCard(c: RatingComparison, onClick: () -> Unit) {
    Column(Modifier.width(150.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        FocusSurface(onClick, Modifier.fillMaxWidth().aspectRatio(0.675f), glow = true) {
            RemoteImage(c.entry.poster, c.entry.name, Modifier.fillMaxSize())
            val diff = c.difference
            Text(
                (if (diff >= 0) "+" else "") + "%.1f".format(java.util.Locale.ITALY, diff),
                Modifier.align(Alignment.TopEnd).padding(7.dp).clip(RoundedCornerShape(8.dp)).background(if (diff >= 0) AetherColors.Success else AetherColors.Danger).padding(horizontal = 7.dp, vertical = 2.dp),
                style = MaterialTheme.typography.labelMedium, color = Color.White,
            )
        }
        Text(c.entry.name, style = MaterialTheme.typography.labelMedium, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text("Tu ${"%.0f".format(c.mine)} · pubblico ${"%.1f".format(java.util.Locale.ITALY, c.public)}", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted, maxLines = 1)
    }
}

@Composable
private fun DiaryCard(e: DiaryEntry, requester: FocusRequester?, onFocused: () -> Unit, onClick: () -> Unit) {
    Column(Modifier.width(150.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        FocusSurface(onClick, Modifier.fillMaxWidth().aspectRatio(0.675f), glow = true, focusRequester = requester, onFocused = onFocused) {
            RemoteImage(e.poster, e.name, Modifier.fillMaxSize())
            if (e.rewatch) Text("RIVISTO", Modifier.align(Alignment.TopStart).padding(7.dp).clip(RoundedCornerShape(8.dp)).background(LocalAccent.current).padding(horizontal = 6.dp, vertical = 2.dp), style = MaterialTheme.typography.labelSmall, color = Color.White)
        }
        Text(e.name, style = MaterialTheme.typography.labelMedium, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(listOfNotNull(dateLabel(e.watchedAt), e.rating?.let { stars(it) }).joinToString(" · "), style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted, maxLines = 1)
        e.episodeLabel?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, maxLines = 1, overflow = TextOverflow.Ellipsis) }
    }
}

fun stars(halfStars: Int): String { val full = halfStars / 2; return "★".repeat(full) + if (halfStars % 2 == 1) "½" else "" }

private fun dateLabel(millis: Long): String = java.time.Instant.ofEpochMilli(millis).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
    .format(java.time.format.DateTimeFormatter.ofPattern("d MMM yyyy", java.util.Locale.ITALIAN))

/** Name and avatar. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ProfileEditor(profile: app.aether.core.profile.ProfileSettings, onChange: ((app.aether.core.profile.ProfileSettings) -> app.aether.core.profile.ProfileSettings) -> Unit, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf(profile.name) }
    val field = remember { FocusRequester() }
    AetherDialog("Il tuo profilo", { onChange { it.copy(name = name.take(40)) }; onDismiss() }, width = 820.dp) {
        TvTextField(name, { name = it.take(40) }, "Il tuo nome", Modifier.fillMaxWidth(), focusRequester = field, onImeAction = { onChange { it.copy(name = name.take(40)) } })
        Text("Scegli l'avatar", style = MaterialTheme.typography.titleSmall, color = AetherColors.OnSurfaceMuted)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ProfileAvatars.all.forEach { a ->
                FocusSurface({ onChange { it.copy(avatar = a.id) } }, Modifier.size(64.dp), shape = CircleShape, focusScale = 1.15f, glow = true, testTag = "profile.avatar.${a.id}", containerColor = Color.Transparent, focusedContainerColor = Color.Transparent) {
                    ProfileAvatarView(a.id, Modifier.fillMaxSize(), ring = a.id == profile.avatar)
                }
            }
        }
        TvButton("Fatto", { onChange { it.copy(name = name.take(40)) }; onDismiss() }, primary = true)
        RequestFocusOnce(field)
    }
}

/** A viewing of the diary: its rating in half stars, rewatch, delete. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DiaryEditor(entry: DiaryEntry, onSave: (DiaryEntry) -> Unit, onDelete: (() -> Unit)?, onOpen: (() -> Unit)? = null, onDismiss: () -> Unit) {
    var rating by remember { mutableStateOf(entry.rating) }
    var rewatch by remember { mutableStateOf(entry.rewatch) }
    val first = remember { FocusRequester() }
    AetherDialog(entry.name, onDismiss, width = 760.dp) {
        Text(listOfNotNull(entry.episodeLabel, dateLabel(entry.watchedAt)).joinToString(" · "), style = MaterialTheme.typography.labelLarge, color = AetherColors.OnSurfaceMuted)
        Text("Il tuo voto", style = MaterialTheme.typography.titleSmall, color = AetherColors.OnBackground)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            TvChip("Nessuno", rating == null, { rating = null }, focusRequester = if (rating == null) first else null)
            (1..10).forEach { v -> TvChip(stars(v), rating == v, { rating = v }, focusRequester = if (rating == v) first else null, testTag = "diary.rating.$v") }
        }
        TvChip(if (rewatch) "Rivisto ✓" else "Era la prima volta", rewatch, { rewatch = !rewatch })
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TvButton("Salva", { onSave(entry.copy(rating = rating, rewatch = rewatch)) }, primary = true, testTag = "diary.save")
            onOpen?.let { TvButton("Apri la scheda", it) }
            onDelete?.let { TvButton("Togli dal diario", it) }
        }
        RequestFocusOnce(first)
    }
}
