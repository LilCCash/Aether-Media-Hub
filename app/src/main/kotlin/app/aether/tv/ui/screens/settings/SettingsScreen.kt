package app.aether.tv.ui.screens.settings

import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.filled.ChevronRight

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.aether.core.AetherEngine
import fi.iki.elonen.NanoHTTPD
import app.aether.tv.ui.components.AetherLogo
import app.aether.core.debrid.DebridError
import app.aether.core.settings.GraphicsQuality
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.background
import androidx.compose.ui.draw.clip
import app.aether.tv.ui.components.FocusSurface
import app.aether.core.debrid.DebridService
import app.aether.core.metadata.MdbListClient
import app.aether.core.metadata.MetadataEnrichment
import app.aether.core.library.BackupCodec
import app.aether.core.library.BackupContents
import app.aether.core.library.BackupError
import app.aether.core.playback.StreamOrdering
import app.aether.core.playback.VideoQualityCap
import app.aether.core.search.SearchSort
import app.aether.core.settings.AccentChoice
import app.aether.core.settings.AppSettings
import app.aether.core.settings.PosterSize
import app.aether.tv.BuildConfig
import app.aether.tv.aether
import app.aether.tv.ui.components.AetherDialog
import app.aether.tv.ui.components.ChoiceDialog
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvTextField
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAccent
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val languageChoices = listOf("it" to "Italiano", "en" to "Inglese", "fr" to "Francese", "es" to "Spagnolo", "de" to "Tedesco", "pt" to "Portoghese", "ru" to "Russo", "ja" to "Giapponese")

@Composable
fun SettingsScreen(onOpenAbout: () -> Unit, onOpenTrakt: () -> Unit = {}, onOpenLive: () -> Unit = {}, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val engine = context.aether
    val scope = rememberCoroutineScope()
    val settings by engine.settings.value.collectAsStateWithLifecycle()
    var dialog by remember { mutableStateOf<(@Composable () -> Unit)?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    val first = remember { FocusRequester() }
    var tab by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableIntStateOf(0) }
    RequestFocusOnce(first)

    fun update(change: (AppSettings) -> AppSettings) { engine.settings.update(change); engine.syncLibraryPolicy() }
    fun close() { dialog = null }

    fun <T> choose(title: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
        dialog = { ChoiceDialog(title, options, selected, onSelect, ::close) }
    }

    val a = settings.appearance
    val p = settings.playback
    val c = settings.content
    val n = settings.network
    val updateState by app.aether.tv.updates.AppUpdater.state.collectAsStateWithLifecycle()

    // tvOS layout: the categories on the left (moving onto one shows it), the rows of the chosen one on the right.
    androidx.compose.foundation.layout.Row(modifier.fillMaxSize().padding(start = AetherDimens.ScreenHorizontal, top = 12.dp)) {
        // The categories scroll: on a 540 dp tall screen eight of them do not all fit under the title (Informazioni was cut off).
        LazyColumn(Modifier.width(300.dp).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(4.dp), contentPadding = PaddingValues(bottom = 40.dp)) {
            item { Text("Impostazioni", style = MaterialTheme.typography.displaySmall, color = AetherColors.OnBackground, modifier = Modifier.padding(start = 6.dp, bottom = 10.dp)) }
            items(settingsTabs.size) { i ->
                val name = settingsTabs[i]
                FocusSurface(
                    onClick = { tab = i },
                    modifier = Modifier.fillMaxWidth().height(46.dp),
                    shape = RoundedCornerShape(14.dp),
                    focusScale = 1.04f,
                    containerColor = if (tab == i) Color(0x33FFFFFF) else Color.Transparent,
                    focusedContainerColor = Color.White,
                    edge = false,
                    focusRequester = if (i == tab) first else null,
                    testTag = "settings.tab.$i",
                    onFocused = { tab = i },
                ) { focused ->
                    val tint = if (focused) AetherColors.OnFocused else if (tab == i) AetherColors.OnBackground else AetherColors.OnSurfaceMuted
                    androidx.compose.foundation.layout.Row(Modifier.align(Alignment.CenterStart).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                        androidx.compose.material3.Icon(settingsIcons[i], null, Modifier.size(22.dp), tint = if (tab == i && !focused) LocalAccent.current else tint)
                        Text(name, style = MaterialTheme.typography.titleMedium, color = tint, modifier = Modifier.padding(start = 14.dp))
                    }
                }
            }
        }
        LazyColumn(Modifier.weight(1f).fillMaxHeight(), contentPadding = PaddingValues(start = 36.dp, end = AetherDimens.ScreenHorizontal, top = 70.dp, bottom = 56.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            notice?.let { text -> item(key = "notice") { Text(text, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnBackground, modifier = Modifier.clip(RoundedCornerShape(12.dp)).background(Color(0x1AFFFFFF)).padding(horizontal = 16.dp, vertical = 10.dp)) } }
            if (tab == 0) {
            val autoLevel = app.aether.tv.ui.theme.Graphics.autoLevel(context)
            val g = app.aether.tv.ui.theme.Graphics.resolve(a, autoLevel)
            section("Grafica e prestazioni")
            choiceRow("Grafica", if (a.graphics == GraphicsQuality.AUTO) "Automatica (${autoLevel.title})" else a.graphics.title, "appearance.graphics") {
                choose("Grafica", GraphicsQuality.entries.map { it to "${it.title} — ${it.detail}" }, a.graphics) { v -> update { it.copy(appearance = it.appearance.copy(graphics = v, graphicsOverrides = app.aether.core.settings.GraphicsOverrides())) } }
            }
            toggleRow("Animazioni", "Ingrandimenti, dissolvenze e movimenti dell'interfaccia.", a.animationsEnabled && g.animations, "appearance.animations") { v -> update { it.copy(appearance = it.appearance.copy(animationsEnabled = v)) } }
            toggleRow("Ombre sotto l'elemento scelto", "Il «sollevamento» di locandine e pulsanti sotto il telecomando.", g.shadows, "appearance.shadows") { v -> update { it.copy(appearance = it.appearance.copy(graphicsOverrides = it.appearance.graphicsOverrides.copy(shadows = v))) } }
            toggleRow("Immagini dietro le pagine", "La locandina sfumata dietro le schede e la luce colorata di sfondo.", g.backdropArt, "appearance.backdropArt") { v -> update { it.copy(appearance = it.appearance.copy(graphicsOverrides = it.appearance.graphicsOverrides.copy(backdropArt = v))) } }
            toggleRow("Sfocature", if (android.os.Build.VERSION.SDK_INT >= 31) "Vetro sfocato dietro pannelli e scheda (il più pesante)." else "Serve Android 12: su questa TV non è disponibile.", g.blur, "appearance.blur") { v -> update { it.copy(appearance = it.appearance.copy(graphicsOverrides = it.appearance.graphicsOverrides.copy(blur = v))) } }
            toggleRow("Dissolvenza delle immagini", "Le locandine compaiono sfumando invece che di colpo.", g.imageFades, "appearance.fades") { v -> update { it.copy(appearance = it.appearance.copy(graphicsOverrides = it.appearance.graphicsOverrides.copy(imageFades = v))) } }
            choiceRow("Margini dello schermo", if (a.overscanPercent == 0) "Standard" else "+${a.overscanPercent}%", "appearance.overscan") {
                choose("Margini dello schermo", (0..6).map { it to if (it == 0) "Standard (consigliato)" else "+$it% — se la TV taglia i bordi" }, a.overscanPercent) { v -> update { it.copy(appearance = it.appearance.copy(overscanPercent = v)) } }
            }
            section("Aspetto")
            choiceRow("Colore d'accento", a.accent.title, "appearance.accent") { choose("Colore d'accento", AccentChoice.entries.map { it to it.title }, a.accent) { v -> update { it.copy(appearance = it.appearance.copy(accent = v)) } } }
            choiceRow("Dimensione delle locandine", a.posterSize.title, "appearance.posterSize") { choose("Dimensione delle locandine", PosterSize.entries.map { it to it.title }, a.posterSize) { v -> update { it.copy(appearance = it.appearance.copy(posterSize = v)) } } }
            choiceRow("Sfondo", a.background.title, "appearance.background") { choose("Sfondo", app.aether.core.settings.BackgroundStyle.entries.map { it to it.title }, a.background) { v -> update { it.copy(appearance = it.appearance.copy(background = v)) } } }
            choiceRow("Angoli di locandine e pulsanti", a.corners.title, "appearance.corners") { choose("Angoli di locandine e pulsanti", app.aether.core.settings.CornerStyle.entries.map { it to it.title }, a.corners) { v -> update { it.copy(appearance = it.appearance.copy(corners = v)) } } }
            actionRow("Personalizza la Home", "Ordine delle sezioni e quali mostrare.", "appearance.homeLayout") { dialog = { HomeLayoutDialog(::close) } }
            toggleRow("Saluto in cima alla Home", "«Ciao, ${a.greetingName.ifBlank { "…" }}!» sopra i titoli.", a.showGreeting, "appearance.greeting") { v -> update { it.copy(appearance = it.appearance.copy(showGreeting = v)) } }
            actionRow("Il tuo nome", a.greetingName.ifBlank { "Non impostato" }, "appearance.name") {
                var text by mutableStateOf(a.greetingName)
                dialog = { TextDialog("Il tuo nome", "Usato per il saluto della Home. Resta solo su questo dispositivo.", text, false, { text = it }, { update { s -> s.copy(appearance = s.appearance.copy(greetingName = text.trim().take(30), showGreeting = text.isNotBlank() || s.appearance.showGreeting)) }; close() }, ::close) }
            }
            toggleRow("Titoli in evidenza", "Il grande riquadro con i titoli in cima alla Home.", a.showHero, "appearance.hero") { v -> update { it.copy(appearance = it.appearance.copy(showHero = v)) } }
            toggleRow("Titolo in evidenza che scorre", "Nella Home passa da un titolo all'altro da solo.", a.heroAutoScroll, "appearance.heroAuto") { v -> update { it.copy(appearance = it.appearance.copy(heroAutoScroll = v)) } }
            toggleRow("Mostra «Continua a guardare»", "Nella Home.", a.showContinueWatching, "appearance.continue") { v -> update { it.copy(appearance = it.appearance.copy(showContinueWatching = v)) } }
            toggleRow("Mostra «Prossimo episodio»", "Nella Home, per le serie che stai seguendo.", a.showNextUp, "appearance.nextUp") { v -> update { it.copy(appearance = it.appearance.copy(showNextUp = v)) } }
            }

            if (tab == 1) {
            toggleRow("Riprendi da dove eri", "Riparte dal punto in cui avevi lasciato.", p.autoResume, "playback.autoResume") { v -> update { it.copy(playback = it.playback.copy(autoResume = v)) } }
            choiceRow("Amplificazione audio", if (p.audioGainDb == 0) "Disattivata" else "+${p.audioGainDb} dB", "playback.audioGain") { choose("Amplificazione audio", listOf(0 to "Disattivata", 3 to "+3 dB", 6 to "+6 dB", 9 to "+9 dB", 12 to "+12 dB", 18 to "+18 dB"), p.audioGainDb) { v -> update { it.copy(playback = it.playback.copy(audioGainDb = v)) } } }
            toggleRow("Finestra piccola (Picture-in-Picture)", "Premendo Home durante un video, continua in un riquadro (se la TV lo permette).", p.pictureInPicture, "playback.pip") { v -> update { it.copy(playback = it.playback.copy(pictureInPicture = v)) } }
            toggleRow("Logo del film mentre carico", "Mostra il logo del titolo (da fanart.tv) mentre la sorgente si prepara.", p.showTitleLogos, "playback.logos") { v -> update { it.copy(playback = it.playback.copy(showTitleLogos = v)) } }
            toggleRow("Rimuovi le annotazioni per non udenti", "Toglie «[porta che sbatte]», «(sospira)» e le note musicali dai sottotitoli.", p.stripHearingImpairedTags, "playback.stripHearing") { v -> update { it.copy(playback = it.playback.copy(stripHearingImpairedTags = v)) } }
            choiceRow("Sincronia predefinita dei sottotitoli", subtitleShift(p.subtitleDelayMillis), "playback.subDelay") { choose("Sincronia predefinita dei sottotitoli", listOf(-5000L, -3000L, -2000L, -1000L, -500L, 0L, 500L, 1000L, 2000L, 3000L, 5000L).map { it to subtitleShift(it) }, p.subtitleDelayMillis) { v -> update { it.copy(playback = it.playback.copy(subtitleDelayMillis = v)) } } }
            choiceRow("Timer di spegnimento predefinito", if (p.defaultSleepTimerMinutes == 0) "Spento" else "${p.defaultSleepTimerMinutes} min", "playback.sleep") { choose("Timer di spegnimento predefinito", listOf(0, 15, 30, 45, 60, 90, 120).map { it to if (it == 0) "Spento" else "$it min" }, p.defaultSleepTimerMinutes) { v -> update { it.copy(playback = it.playback.copy(defaultSleepTimerMinutes = v)) } } }
            choiceRow("Riavvolgi alla ripresa", "${p.resumeRewindSeconds} s", "playback.rewind") { choose("Riavvolgi alla ripresa", listOf(0, 5, 10, 15).map { it to "$it s" }, p.resumeRewindSeconds) { v -> update { it.copy(playback = it.playback.copy(resumeRewindSeconds = v)) } } }
            choiceRow("Salto indietro", "${p.skipBackSeconds} s", "playback.skipBack") { choose("Salto indietro", listOf(5, 10, 15, 30).map { it to "$it s" }, p.skipBackSeconds) { v -> update { it.copy(playback = it.playback.copy(skipBackSeconds = v)) } } }
            choiceRow("Salto avanti", "${p.skipForwardSeconds} s", "playback.skipForward") { choose("Salto avanti", listOf(5, 10, 15, 30).map { it to "$it s" }, p.skipForwardSeconds) { v -> update { it.copy(playback = it.playback.copy(skipForwardSeconds = v)) } } }
            toggleRow("Episodio successivo automatico", "A fine episodio parte il prossimo, dopo un conto alla rovescia.", p.autoplayNextEpisode, "playback.autoNext") { v -> update { it.copy(playback = it.playback.copy(autoplayNextEpisode = v)) } }
            choiceRow("Conto alla rovescia", "${p.nextEpisodeCountdownSeconds} s", "playback.countdown") { choose("Conto alla rovescia", listOf(3, 5, 8, 10, 15).map { it to "$it s" }, p.nextEpisodeCountdownSeconds) { v -> update { it.copy(playback = it.playback.copy(nextEpisodeCountdownSeconds = v)) } } }
            choiceRow("Lingua dell'audio", languageLabel(p.preferredAudioLanguage, "Quella della TV"), "playback.audioLanguage") { choose("Lingua dell'audio", listOf("system" to "Quella della TV") + languageChoices, p.preferredAudioLanguage) { v -> update { it.copy(playback = it.playback.copy(preferredAudioLanguage = v)) } } }
            choiceRow("Lingua dei sottotitoli", languageLabel(p.preferredSubtitleLanguage, "Quella della TV"), "playback.subtitleLanguage") { choose("Lingua dei sottotitoli", listOf("off" to "Disattivati", "system" to "Quella della TV") + languageChoices, p.preferredSubtitleLanguage) { v -> update { it.copy(playback = it.playback.copy(preferredSubtitleLanguage = v)) } } }
            choiceRow("Dimensione dei sottotitoli", "${p.subtitleStyle.sizePercent}%", "playback.subSize") { choose("Dimensione dei sottotitoli", listOf(70, 85, 100, 125, 150, 200).map { it to "$it%" }, p.subtitleStyle.sizePercent) { v -> update { it.copy(playback = it.playback.copy(subtitleStyle = it.playback.subtitleStyle.copy(sizePercent = v))) } } }
            choiceRow("Colore dei sottotitoli", colorLabel(p.subtitleStyle.textColor), "playback.subColor") { choose("Colore dei sottotitoli", listOf(0xFFFFFFFFL to "Bianco", 0xFFFFE066L to "Giallo", 0xFF9BE7FFL to "Azzurro", 0xFFB6F5B6L to "Verde"), p.subtitleStyle.textColor) { v -> update { it.copy(playback = it.playback.copy(subtitleStyle = it.playback.subtitleStyle.copy(textColor = v))) } } }
            choiceRow("Sfondo dei sottotitoli", "${p.subtitleStyle.backgroundOpacityPercent}%", "playback.subBackground") { choose("Sfondo dei sottotitoli", listOf(0, 25, 50, 75).map { it to if (it == 0) "Nessuno" else "$it%" }, p.subtitleStyle.backgroundOpacityPercent) { v -> update { it.copy(playback = it.playback.copy(subtitleStyle = it.playback.subtitleStyle.copy(backgroundOpacityPercent = v))) } } }
            choiceRow("Altezza dei sottotitoli", "${p.subtitleStyle.bottomOffsetPercent}% dal basso", "playback.subOffset") { choose("Altezza dei sottotitoli", listOf(2, 5, 8, 12, 16, 22).map { it to "$it% dal basso" }, p.subtitleStyle.bottomOffsetPercent) { v -> update { it.copy(playback = it.playback.copy(subtitleStyle = it.playback.subtitleStyle.copy(bottomOffsetPercent = v))) } } }
            toggleRow("Contorno dei sottotitoli", "Un bordo scuro intorno alle lettere.", p.subtitleStyle.outline, "playback.subOutline") { v -> update { it.copy(playback = it.playback.copy(subtitleStyle = it.playback.subtitleStyle.copy(outline = v))) } }
            toggleRow("Sottotitoli in grassetto", "", p.subtitleStyle.bold, "playback.subBold") { v -> update { it.copy(playback = it.playback.copy(subtitleStyle = it.playback.subtitleStyle.copy(bold = v))) } }
            choiceRow("Qualità massima", p.qualityCap.title, "playback.quality") { choose("Qualità massima", VideoQualityCap.entries.map { it to it.title }, p.qualityCap) { v -> update { it.copy(playback = it.playback.copy(qualityCap = v)) } } }
            toggleRow("Preferisci sorgenti nella tua lingua", "Nell'ordine delle sorgenti, quelle con l'audio che preferisci vengono prima.", p.preferStreamsInPreferredLanguage, "playback.preferLanguage") { v -> update { it.copy(playback = it.playback.copy(preferStreamsInPreferredLanguage = v)) } }
            choiceRow("Ordine delle sorgenti", if (p.streamOrdering == StreamOrdering.BY_ADDON) "Per addon" else "Le migliori per prime", "playback.ordering") {
                choose("Ordine delle sorgenti", listOf(StreamOrdering.BY_ADDON to "Per addon: prima quelle del primo addon della lista", StreamOrdering.BEST to "Le migliori per prime, da qualunque addon"), p.streamOrdering) { v -> update { it.copy(playback = it.playback.copy(streamOrdering = v)) } }
            }
            toggleRow("Scegli la sorgente da solo", "Parte subito con la migliore, senza mostrare l'elenco.", p.autoSelectStream, "playback.autoSelect") { v -> update { it.copy(playback = it.playback.copy(autoSelectStream = v)) } }
            choiceRow("Nascondi i controlli dopo", "${p.controlsAutoHideSeconds} s", "playback.controlsHide") { choose("Nascondi i controlli dopo", listOf(3, 4, 6, 8, 12).map { it to "$it s" }, p.controlsAutoHideSeconds) { v -> update { it.copy(playback = it.playback.copy(controlsAutoHideSeconds = v)) } } }
            choiceRow("Segna come visto a", "${(p.watchedThreshold * 100).toInt()}%", "playback.watched") { choose("Segna come visto a", listOf(0.8, 0.9, 0.95).map { it to "${(it * 100).toInt()}%" }, p.watchedThreshold) { v -> update { it.copy(playback = it.playback.copy(watchedThreshold = v)) } } }
            toggleRow("Salta intro e riassunto", "Mostra il pulsante per saltarli, con i dati di IntroDB (si consulta con il codice IMDb, la stagione e l'episodio).", p.skipSegmentsEnabled, "playback.skipSegments") { v -> update { it.copy(playback = it.playback.copy(skipSegmentsEnabled = v)) } }
            }

            if (tab == 2) {
            toggleRow("Nascondi gli addon per adulti", "Non mostra i cataloghi degli addon che si dichiarano per adulti.", c.hideAdultCatalogs, "content.hideAdult") { v -> update { it.copy(content = it.content.copy(hideAdultCatalogs = v)) } }
            toggleRow("Salva le ricerche recenti", "", c.saveSearchHistory, "content.saveSearch") { v -> update { it.copy(content = it.content.copy(saveSearchHistory = v)) } }
            toggleRow("Cerca anche nella libreria", "I titoli salvati o guardati compaiono tra i risultati, anche senza rete.", c.searchLocal, "content.searchLocal") { v -> update { it.copy(content = it.content.copy(searchLocal = v)) } }
            choiceRow("Lingua di trama e dettagli", metaLanguages.firstOrNull { it.first == c.metadataLanguage }?.second ?: c.metadataLanguage, "content.metaLang") { choose("Lingua di trama e dettagli", metaLanguages, c.metadataLanguage) { v -> update { it.copy(content = it.content.copy(metadataLanguage = v)) }; engine.metadata.clearCaches() } }
            choiceRow("Ordine dei risultati", c.searchSort.title, "content.searchSort") { choose("Ordine dei risultati", SearchSort.entries.map { it to it.title }, c.searchSort) { v -> update { it.copy(content = it.content.copy(searchSort = v)) } } }
            choiceRow("Aggiorna i cataloghi ogni", "${c.catalogRefreshMinutes} min", "content.refresh") { choose("Aggiorna i cataloghi ogni", listOf(5, 10, 30, 60, 180).map { it to "$it min" }, c.catalogRefreshMinutes) { v -> update { it.copy(content = it.content.copy(catalogRefreshMinutes = v)) } } }
            }

            if (tab == 3) {
            fun keyRow(title: String, key: String, tag: String, hint: String) = actionRow(title, if (engine.secrets.get(key).isNullOrBlank()) "Non impostata" else "Impostata · cifrata sul dispositivo", tag) {
                var text by mutableStateOf("")
                dialog = { TextDialog(title, "$hint Lascia vuoto per rimuoverla. Digitare con il telecomando è lento: dal telefono puoi usare «Inserisci le chiavi dal telefono».", text, true, { text = it }, {
                    if (text.isBlank()) engine.secrets.remove(key) else engine.secrets.put(key, text.trim())
                    engine.metadata.clearCaches()
                    notice = if (text.isBlank()) "$title rimossa." else "$title salvata. Usa «Verifica» per controllarla."
                    close()
                }, ::close) }
            }
            keyRow("Chiave TMDB", MetadataEnrichment.TMDbKey, "metadata.tmdb", "Chiave API v3 (32 caratteri) oppure token di lettura v4 («eyJ…»). Aggiunge cast con foto, trailer, produzioni e titoli simili.")
            actionRow("Verifica TMDB", "Controlla che TMDB accetti la chiave.", "metadata.tmdb.verify") { scope.launch { notice = "Controllo TMDB…"; notice = engine.metadata.checkTmdb()?.let { "TMDB: $it" } ?: "TMDB: chiave accettata." } }
            keyRow("Chiave TheTVDB", MetadataEnrichment.TVDbKey, "metadata.tvdb", "Chiave API v4. Aggiunge trame, locandine e immagini degli episodi.")
            keyRow("Chiave fanart.tv (facoltativa)", MetadataEnrichment.FanartKey, "metadata.fanart", "La tua chiave personale di fanart.tv: mostra i loghi dei titoli. Senza chiave i loghi non compaiono.")
            keyRow("Chiave MDBList (facoltativa)", MdbListClient.KEY_SECRET, "metadata.mdblist", "La chiave di mdblist.com: aggiunge nella scheda i voti di IMDb, Rotten Tomatoes, Metacritic, Letterboxd e altri.")
            actionRow("Verifica MDBList", "Controlla che MDBList accetti la chiave.", "metadata.mdblist.verify") { scope.launch { notice = "Controllo MDBList…"; notice = engine.mdbList.check()?.let { "MDBList: $it" } ?: "MDBList: chiave accettata." } }
            keyRow("PIN TheTVDB", MetadataEnrichment.TVDbPin, "metadata.tvdbPin", "Solo per le chiavi degli abbonati.")
            actionRow("Verifica TheTVDB", "Controlla che TheTVDB accetti la chiave.", "metadata.tvdb.verify") { scope.launch { notice = "Controllo TheTVDB…"; notice = engine.metadata.checkTvdb()?.let { "TheTVDB: $it" } ?: "TheTVDB: chiave accettata." } }
            actionRow("Chiavi e backup dal telefono", "Apre una pagina sul telefono (stessa Wi-Fi): inserisci le chiavi dei servizi o carica un file di backup.", "metadata.phone") {
                dialog = { app.aether.tv.remote.PhoneConfigDialog(::close) }
            }
            }

            if (tab == 4) {
            toggleRow("Consenti la rete locale", "Permette addon su indirizzi di casa (192.168.x.x, un NAS). Attivala solo se sai cosa stai collegando.", n.allowLocalNetwork, "network.local") { v -> update { it.copy(network = it.network.copy(allowLocalNetwork = v)) } }
            toggleRow("Ricorda le risposte degli addon", "Più veloce e funziona anche quando un addon è lento; si può spegnere.", n.cacheResponses, "network.cache") { v -> update { it.copy(network = it.network.copy(cacheResponses = v)) } }
            actionRow("Server di streaming per i torrent", n.streamingServerUrl.ifBlank { "Non impostato" }, "network.server") {
                var text by mutableStateOf(n.streamingServerUrl)
                dialog = { TextDialog("Server di streaming", "Indirizzo di un server compatibile con Stremio che hai in casa (per esempio http://192.168.1.20:11470). Serve per i torrent senza TorBox.", text, false, { text = it }, { update { s -> s.copy(network = s.network.copy(streamingServerUrl = text.trim())) }; close() }, ::close) }
            }
            actionRow("Svuota la memoria temporanea", "Risposte degli addon e immagini scaricate.", "network.clearCache") {
                engine.cache.clear()
                scope.launch(Dispatchers.IO) { context.cacheDir.resolve("images").deleteRecursively() }
                notice = "Memoria temporanea svuotata."
            }
            }

            if (tab == 5) {
            choiceRow("Servizio debrid in uso", n.debridService.title, "services.debrid") {
                choose("Servizio debrid in uso", DebridService.entries.map { it to it.title }, n.debridService) { v -> update { it.copy(network = it.network.copy(debridService = v)) } }
            }
            actionRow("Chiave TorBox", if (engine.torBox.isConfigured) "Impostata · cifrata sul dispositivo" else "Non impostata", "services.torbox") {
                var text by mutableStateOf("")
                dialog = {
                    TextDialog("Chiave TorBox", "Serve per riprodurre i torrent tramite il tuo account TorBox. La chiave resta sul dispositivo, cifrata, e viene mandata solo a TorBox.", text, true, { text = it }, {
                        try { engine.torBox.saveKey(text); scope.launch { notice = verifyKey(engine) } } catch (_: IllegalArgumentException) { notice = "La chiave non è valida: niente spazi o caratteri speciali." }
                        close()
                    }, ::close)
                }
            }
            if (engine.torBox.isConfigured) {
                actionRow("Verifica la chiave TorBox", "Controlla che TorBox la riconosca.", "services.torbox.verify") { scope.launch { notice = "Controllo…"; notice = verifyKey(engine) } }
                actionRow("Rimuovi la chiave TorBox", "Cancella la chiave dal dispositivo.", "services.torbox.remove") { engine.torBox.removeKey(); notice = "Chiave TorBox rimossa." }
            }
            actionRow("Token Real-Debrid", if (engine.realDebrid.isConfigured) "Impostato · cifrato sul dispositivo" else "Non impostato", "services.realdebrid") {
                var text by mutableStateOf("")
                dialog = {
                    TextDialog("Token Real-Debrid", "Il token API privato da real-debrid.com/apitoken. Resta sul dispositivo, cifrato; va solo a Real-Debrid e negli indirizzi di Torrentio e Comet quando Real-Debrid è il servizio in uso.", text, true, { text = it }, {
                        try { engine.realDebrid.saveKey(text); scope.launch { notice = verifyRealDebrid(engine) } } catch (_: IllegalArgumentException) { notice = "Il token non è valido: niente spazi o caratteri speciali." }
                        close()
                    }, ::close)
                }
            }
            actionRow("Trakt", if (engine.trakt.client.isConnected) "Collegato: sincronizzazione, scrobble e cataloghi" else "Collega il tuo account con un codice", "services.trakt") { onOpenTrakt() }
            actionRow("TV in diretta", if (settings.liveTv.playlists.isEmpty()) "Aggiungi playlist M3U e la guida dei programmi" else "${settings.liveTv.playlists.size} playlist", "services.live") {
                engine.settings.update { it.copy(liveTv = it.liveTv.copy(showTab = true)) }
                onOpenLive()
            }
            if (engine.realDebrid.isConfigured) {
                actionRow("Verifica il token Real-Debrid", "Controlla che Real-Debrid lo riconosca.", "services.realdebrid.verify") { scope.launch { notice = "Controllo…"; notice = verifyRealDebrid(engine) } }
                actionRow("Rimuovi il token Real-Debrid", "Cancella il token dal dispositivo.", "services.realdebrid.remove") { engine.realDebrid.removeKey(); notice = "Token Real-Debrid rimosso." }
            }
            }

            if (tab == 6) {
            toggleRow("Registra la cronologia", "Ricorda cosa guardi e dove ti fermi. Spenta, «Continua a guardare» non si aggiorna.", settings.privacy.recordHistory, "privacy.history") { v -> update { it.copy(privacy = it.privacy.copy(recordHistory = v)) } }
            actionRow("Cancella la cronologia", "Anche i punti in cui ti sei fermato.", "privacy.clearHistory") { engine.library.clearHistory(); notice = "Cronologia cancellata." }
            actionRow("Cancella le ricerche recenti", "", "privacy.clearSearch") { engine.library.clearSearchHistory(); notice = "Ricerche cancellate." }
            actionRow("Esporta un backup", "Libreria, cronologia e (se vuoi) gli indirizzi degli addon, in un file.", "data.export") { dialog = { ExportDialog(engine, context, ::close) { notice = it } } }
            actionRow("Ripristina da un backup", "Un file creato da Aether per Android TV o per iPhone.", "data.import") { dialog = { ImportDialog(engine, context, ::close) { notice = it } } }
            actionRow("Ripristina le impostazioni", "Riporta le impostazioni ai valori iniziali (non tocca addon e libreria).", "data.resetSettings") { engine.settings.reset(); notice = "Impostazioni ripristinate." }
            actionRow("Cancella tutti i dati", "Addon, libreria, cronologia, impostazioni e chiavi.", "data.wipe") {
                dialog = { ConfirmDialog("Cancellare tutto?", "Verranno cancellati addon, libreria, cronologia, impostazioni e le chiavi dei servizi. Non si può annullare.", "Cancella tutto", {
                    scope.launch { engine.registry.removeAll(); engine.library.deleteAll(); engine.settings.reset(); engine.torBox.removeKey(); engine.realDebrid.removeKey(); engine.cache.clear(); notice = "Tutti i dati sono stati cancellati." }; close()
                }, ::close) }
            }
            }

            if (tab == 7) {
            actionRow("Informazioni su Aether", "Versione ${BuildConfig.VERSION_NAME}, licenze e avvertenze.", "about.open") { onOpenAbout() }
            actionRow("Cerca aggiornamenti", when (val u = updateState) {
                is app.aether.tv.updates.AppUpdater.State.Available -> "Disponibile la build ${u.info.versionCode} · installata ${app.aether.tv.updates.AppUpdater.currentVersion}"
                is app.aether.tv.updates.AppUpdater.State.UpToDate -> "Sei aggiornato · ${app.aether.tv.updates.AppUpdater.currentVersion}"
                else -> "Installata ${app.aether.tv.updates.AppUpdater.currentVersion}"
            }, "about.updates") {
                scope.launch { app.aether.tv.updates.AppUpdater.check() }
                dialog = { app.aether.tv.updates.UpdateDialog(::close) }
            }
            toggleRow("Controlla gli aggiornamenti all'avvio", "Se c'è una versione nuova, te la propone appena apri l'app.", n.checkUpdatesAtStart, "about.autoUpdate") { v -> update { it.copy(network = it.network.copy(checkUpdatesAtStart = v)) } }
            actionRow("Capacità di questa TV", app.aether.tv.DeviceCapabilities.summary(context), "about.capabilities") { notice = app.aether.tv.DeviceCapabilities.summary(context) }
            }
        }
    }
    dialog?.invoke()
}

private val metaLanguages = listOf("it-IT" to "Italiano", "en-US" to "English", "fr-FR" to "Français", "es-ES" to "Español", "de-DE" to "Deutsch", "pt-PT" to "Português")

private val settingsIcons = listOf(
    androidx.compose.material.icons.Icons.Filled.Palette, androidx.compose.material.icons.Icons.Filled.PlayCircle, androidx.compose.material.icons.Icons.Filled.Movie,
    androidx.compose.material.icons.Icons.Filled.Info, androidx.compose.material.icons.Icons.Filled.Wifi, androidx.compose.material.icons.Icons.Filled.Key,
    androidx.compose.material.icons.Icons.Filled.Storage, androidx.compose.material.icons.Icons.Filled.Star,
)

private val settingsTabs = listOf("Aspetto", "Riproduzione", "Contenuti", "Metadati", "Rete", "Servizi", "Dati", "Informazioni")

private fun languageLabel(code: String, systemLabel: String): String = when (code) { "system" -> systemLabel; "off" -> "Disattivati"; else -> languageChoices.firstOrNull { it.first == code }?.second ?: code }
private fun colorLabel(color: Long): String = when (color) { 0xFFFFE066L -> "Giallo"; 0xFF9BE7FFL -> "Azzurro"; 0xFFB6F5B6L -> "Verde"; else -> "Bianco" }

private suspend fun verifyKey(engine: AetherEngine): String = try {
    val user = engine.torBox.fetchUser()
    "TorBox ha riconosciuto la chiave" + (if (user.isSubscribed == true) " (abbonamento attivo)." else ".")
} catch (e: DebridError) {
    e.message
} catch (e: Throwable) {
    "Non riesco a contattare TorBox."
}

private suspend fun verifyRealDebrid(engine: AetherEngine): String = try {
    val user = engine.realDebrid.fetchUser()
    "Real-Debrid ha riconosciuto il token (account ${user.planName})" + if (user.isPremium) "." else ": molte funzioni richiedono Premium."
} catch (e: DebridError) {
    e.message
} catch (e: Throwable) {
    "Non riesco a contattare Real-Debrid."
}

// MARK: Rows

private fun androidx.compose.foundation.lazy.LazyListScope.section(title: String) {
    item(key = "section-$title") { Text(title.uppercase(), style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceFaint, modifier = Modifier.padding(start = 6.dp, top = 18.dp, bottom = 2.dp)) }
}

private fun androidx.compose.foundation.lazy.LazyListScope.toggleRow(title: String, description: String, checked: Boolean, tag: String, onChange: (Boolean) -> Unit) {
    item(key = tag) { SettingRow(title, description.ifBlank { null }, null, highlight = checked, tag = tag, toggle = checked, onClick = { onChange(!checked) }) }
}

private fun androidx.compose.foundation.lazy.LazyListScope.choiceRow(title: String, value: String, tag: String, requester: FocusRequester? = null, onClick: () -> Unit) {
    item(key = tag) { SettingRow(title, null, value, tag = tag, requester = requester, onClick = onClick) }
}

private fun androidx.compose.foundation.lazy.LazyListScope.actionRow(title: String, description: String, tag: String, onClick: () -> Unit) {
    item(key = tag) { SettingRow(title, description.ifBlank { null }, null, tag = tag, chevron = true, onClick = onClick) }
}

@Composable
private fun SettingRow(title: String, description: String?, value: String?, highlight: Boolean = false, tag: String, requester: FocusRequester? = null, toggle: Boolean? = null, chevron: Boolean = false, onClick: () -> Unit) {
    FocusSurface(
        onClick, Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), focusScale = 1.02f,
        containerColor = AetherColors.Glass, focusedContainerColor = Color.White, edge = false, focusRequester = requester, testTag = tag,
    ) { focused ->
        Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 13.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium, color = if (focused) AetherColors.OnFocused else AetherColors.OnBackground)
                description?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = if (focused) AetherColors.OnFocused.copy(alpha = 0.65f) else AetherColors.OnSurfaceMuted, maxLines = 2, overflow = TextOverflow.Ellipsis) }
            }
            value?.let {
                Text(it, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 16.dp).widthIn(max = 280.dp),
                    color = if (focused) AetherColors.OnFocused.copy(alpha = 0.75f) else if (highlight) LocalAccent.current else AetherColors.OnSurfaceMuted)
                androidx.compose.material3.Icon(androidx.compose.material.icons.Icons.Filled.UnfoldMore, null, Modifier.padding(start = 6.dp).size(20.dp), tint = if (focused) AetherColors.OnFocused.copy(alpha = 0.6f) else AetherColors.OnSurfaceFaint)
            }
            toggle?.let { on -> Switch(on, focused, Modifier.padding(start = 16.dp)) }
            if (chevron) androidx.compose.material3.Icon(androidx.compose.material.icons.Icons.Filled.ChevronRight, null, Modifier.padding(start = 12.dp).size(24.dp), tint = if (focused) AetherColors.OnFocused.copy(alpha = 0.6f) else AetherColors.OnSurfaceFaint)
        }
    }
}

/** An on/off switch in the manner of tvOS: a capsule with a round knob; the accent colour when on. */
@Composable
private fun Switch(on: Boolean, focused: Boolean, modifier: Modifier = Modifier) {
    val graphics = app.aether.tv.ui.theme.LocalGraphics.current
    val accent = LocalAccent.current
    val knob by androidx.compose.animation.core.animateDpAsState(if (on) 22.dp else 2.dp, androidx.compose.animation.core.tween(graphics.ms(160)), label = "switch")
    val track = if (on) accent else if (focused) Color(0x33000000) else Color(0x33FFFFFF)
    Box(modifier.width(50.dp).height(30.dp).clip(RoundedCornerShape(15.dp)).background(track)) {
        Box(Modifier.padding(start = knob, top = 2.dp).size(26.dp).clip(androidx.compose.foundation.shape.CircleShape).background(Color.White))
    }
}

// MARK: Dialogs

@Composable
private fun TextDialog(title: String, message: String, value: String, secret: Boolean, onChange: (String) -> Unit, onSave: () -> Unit, onDismiss: () -> Unit) {
    val field = remember { FocusRequester() }
    AetherDialog(title, onDismiss, width = 720.dp) {
        Text(message, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
        TvTextField(value, onChange, if (secret) "Chiave" else "Indirizzo", secret = secret, focusRequester = field, imeAction = ImeAction.Done, onImeAction = onSave, testTag = "settings.textField")
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TvButton("Salva", onSave, primary = true, testTag = "settings.save")
            TvButton("Annulla", onDismiss)
        }
        RequestFocusOnce(field)
    }
}

@Composable
private fun ConfirmDialog(title: String, message: String, confirm: String, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    val no = remember { FocusRequester() }
    AetherDialog(title, onDismiss, width = 560.dp) {
        Text(message, style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TvButton(confirm, onConfirm, primary = true, testTag = "settings.confirm")
            TvButton("Annulla", onDismiss, focusRequester = no)
        }
        RequestFocusOnce(no)
    }
}

private fun backupDir(context: Context): File = File(context.getExternalFilesDir(null) ?: context.filesDir, "backup").apply { mkdirs() }

@Composable
private fun ExportDialog(engine: AetherEngine, context: Context, onDone: () -> Unit, report: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var withUrls by remember { mutableStateOf(false) }
    var withKeys by remember { mutableStateOf(false) }
    val first = remember { FocusRequester() }
    AetherDialog("Esporta un backup", onDone, width = 700.dp) {
        Text("Il file contiene la tua libreria, la cronologia e le ricerche. Gli indirizzi degli addon possono contenere le tue chiavi personali: includili solo se il backup resta tuo.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
        TvButton(if (withUrls) "Includi gli indirizzi degli addon: sì" else "Includi gli indirizzi degli addon: no", { withUrls = !withUrls }, focusRequester = first, testTag = "export.urls")
        TvButton(if (withKeys) "Includi le chiavi (TMDB, TheTVDB, TorBox): sì" else "Includi le chiavi (TMDB, TheTVDB, TorBox): no", { withKeys = !withKeys }, testTag = "export.keys")
        if (withKeys) Text("Le chiavi restano in chiaro nel file: tienilo al sicuro. Ripristinandolo, i servizi si configurano da soli.", style = MaterialTheme.typography.bodySmall, color = AetherColors.Warning)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TvButton("Salva il backup", {
                scope.launch {
                    val message = withContext(Dispatchers.IO) {
                        try {
                            val urls = if (withUrls) engine.registry.handles(includeDisabled = true).map { it.transportUrl } else emptyList()
                            val text = BackupCodec.encode(engine.library.snapshot(), urls, withUrls, BuildConfig.VERSION_NAME, keys = if (withKeys) engine.backupKeys() else emptyMap())
                            val file = File(backupDir(context), "Aether-backup-" + SimpleDateFormat("yyyyMMdd-HHmm", Locale.US).format(Date()) + ".json")
                            file.writeText(text)
                            "Backup salvato in ${file.absolutePath}"
                        } catch (e: Exception) { "Non sono riuscito a salvare il backup: ${e.message}" }
                    }
                    report(message); onDone()
                }
            }, primary = true, testTag = "export.save")
            TvButton("Annulla", onDone)
        }
        RequestFocusOnce(first)
    }
}

@Composable
private fun ImportDialog(engine: AetherEngine, context: Context, onDone: () -> Unit, report: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var contents by remember { mutableStateOf<BackupContents?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val files = remember { backupDir(context).listFiles { f -> f.extension == "json" }?.sortedByDescending { it.lastModified() }.orEmpty() }
    val first = remember { FocusRequester() }

    fun read(text: String) { try { contents = BackupCodec.decode(text); error = null } catch (e: BackupError) { error = e.message } }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) scope.launch {
            val text = withContext(Dispatchers.IO) { runCatching { context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() } }.getOrNull() }
            if (text == null) error = "Non riesco a leggere il file." else read(text)
        }
    }

    AetherDialog("Ripristina da un backup", onDone, width = 760.dp) {
        val c = contents
        if (c == null) {
            Text("Scegli un backup salvato su questa TV, oppure apri un file con il selettore del sistema (se la TV ne ha uno).", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
            error?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.Danger) }
            LazyColumn(Modifier.height(if (files.isEmpty()) 0.dp else (minOf(files.size, 4) * 56).dp), verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(4.dp)) {
                items(files.size) { i ->
                    FocusSurface({ scope.launch { val text = withContext(Dispatchers.IO) { files[i].readText() }; read(text) } }, Modifier.fillMaxWidth().height(48.dp), focusRequester = if (i == 0) first else null) {
                        Text(files[i].name, Modifier.padding(horizontal = 14.dp).align(Alignment.CenterStart), style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnBackground, maxLines = 1)
                    }
                }
            }
            if (files.isEmpty()) Text("Non ci sono backup salvati su questa TV.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceFaint)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton("Apri un file…", { try { picker.launch(arrayOf("application/json", "text/plain", "*/*")) } catch (_: Exception) { error = "Questa TV non ha un selettore di file." } }, testTag = "import.picker")
                TvButton("Annulla", onDone)
            }
            if (files.isNotEmpty()) RequestFocusOnce(first)
        } else {
            val entries = c.library.entries.values.count { !it.isRemoved }
            Text("Il backup contiene $entries titoli salvati, ${c.library.progress.size} punti di visione e ${c.library.searchHistory.size} ricerche" + (if (c.addonUrls.isNotEmpty()) ", più ${c.addonUrls.size} addon." else "."), style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground)
            if (c.platform == null) Text("Creato da Aether per iPhone: le impostazioni dei due programmi sono diverse e non vengono importate.", style = MaterialTheme.typography.bodySmall, color = AetherColors.OnSurfaceMuted)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton("Unisci a quello che ho", { scope.launch { report(engine.restoreBackup(c, replace = false)); onDone() } }, primary = true, focusRequester = first, testTag = "import.merge")
                TvButton("Sostituisci tutto", { scope.launch { report(engine.restoreBackup(c, replace = true)); onDone() } }, testTag = "import.replace")
                TvButton("Indietro", { contents = null })
            }
            RequestFocusOnce(first)
        }
    }
}

private fun subtitleShift(ms: Long): String = when {
    ms == 0L -> "Nessuna"
    ms > 0 -> "+${ms / 1000.0} s (dopo)"
    else -> "${ms / 1000.0} s (prima)"
}
