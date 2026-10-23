package app.aether.tv.ui.screens.settings

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import app.aether.core.debrid.DebridError
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
fun SettingsScreen(onOpenAbout: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val engine = context.aether
    val scope = rememberCoroutineScope()
    val settings by engine.settings.value.collectAsStateWithLifecycle()
    var dialog by remember { mutableStateOf<(@Composable () -> Unit)?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    val first = remember { FocusRequester() }
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

    Column(modifier.fillMaxSize().padding(top = AetherDimens.ScreenVertical)) {
        Text("Impostazioni", style = MaterialTheme.typography.headlineLarge, color = AetherColors.OnBackground, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
        notice?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = LocalAccent.current, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal, vertical = 4.dp)) }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 12.dp, bottom = 56.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            section("Aspetto")
            choiceRow("Colore d'accento", a.accent.title, "appearance.accent", first) { choose("Colore d'accento", AccentChoice.entries.map { it to it.title }, a.accent) { v -> update { it.copy(appearance = it.appearance.copy(accent = v)) } } }
            choiceRow("Dimensione delle locandine", a.posterSize.title, "appearance.posterSize") { choose("Dimensione delle locandine", PosterSize.entries.map { it to it.title }, a.posterSize) { v -> update { it.copy(appearance = it.appearance.copy(posterSize = v)) } } }
            toggleRow("Animazioni", "Ingrandimenti, dissolvenze e movimenti dell'interfaccia.", a.animationsEnabled, "appearance.animations") { v -> update { it.copy(appearance = it.appearance.copy(animationsEnabled = v)) } }
            toggleRow("Titolo in evidenza che scorre", "Nella Home passa da un titolo all'altro da solo.", a.heroAutoScroll, "appearance.heroAuto") { v -> update { it.copy(appearance = it.appearance.copy(heroAutoScroll = v)) } }
            toggleRow("Mostra «Continua a guardare»", "Nella Home.", a.showContinueWatching, "appearance.continue") { v -> update { it.copy(appearance = it.appearance.copy(showContinueWatching = v)) } }
            toggleRow("Mostra «Prossimo episodio»", "Nella Home, per le serie che stai seguendo.", a.showNextUp, "appearance.nextUp") { v -> update { it.copy(appearance = it.appearance.copy(showNextUp = v)) } }

            section("Riproduzione")
            toggleRow("Riprendi da dove eri", "Riparte dal punto in cui avevi lasciato.", p.autoResume, "playback.autoResume") { v -> update { it.copy(playback = it.playback.copy(autoResume = v)) } }
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

            section("Contenuti e ricerca")
            toggleRow("Nascondi gli addon per adulti", "Non mostra i cataloghi degli addon che si dichiarano per adulti.", c.hideAdultCatalogs, "content.hideAdult") { v -> update { it.copy(content = it.content.copy(hideAdultCatalogs = v)) } }
            toggleRow("Salva le ricerche recenti", "", c.saveSearchHistory, "content.saveSearch") { v -> update { it.copy(content = it.content.copy(saveSearchHistory = v)) } }
            toggleRow("Cerca anche nella libreria", "I titoli salvati o guardati compaiono tra i risultati, anche senza rete.", c.searchLocal, "content.searchLocal") { v -> update { it.copy(content = it.content.copy(searchLocal = v)) } }
            choiceRow("Ordine dei risultati", c.searchSort.title, "content.searchSort") { choose("Ordine dei risultati", SearchSort.entries.map { it to it.title }, c.searchSort) { v -> update { it.copy(content = it.content.copy(searchSort = v)) } } }
            choiceRow("Aggiorna i cataloghi ogni", "${c.catalogRefreshMinutes} min", "content.refresh") { choose("Aggiorna i cataloghi ogni", listOf(5, 10, 30, 60, 180).map { it to "$it min" }, c.catalogRefreshMinutes) { v -> update { it.copy(content = it.content.copy(catalogRefreshMinutes = v)) } } }

            section("Rete")
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

            section("Servizi")
            actionRow("Chiave TorBox", if (engine.torBox.isConfigured) "Impostata" else "Non impostata", "services.torbox") {
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
                actionRow("Rimuovi la chiave TorBox", "Cancella la chiave dal dispositivo.", "services.torbox.remove") { engine.torBox.removeKey(); notice = "Chiave rimossa." }
            }

            section("Privacy e dati")
            toggleRow("Registra la cronologia", "Ricorda cosa guardi e dove ti fermi. Spenta, «Continua a guardare» non si aggiorna.", settings.privacy.recordHistory, "privacy.history") { v -> update { it.copy(privacy = it.privacy.copy(recordHistory = v)) } }
            actionRow("Cancella la cronologia", "Anche i punti in cui ti sei fermato.", "privacy.clearHistory") { engine.library.clearHistory(); notice = "Cronologia cancellata." }
            actionRow("Cancella le ricerche recenti", "", "privacy.clearSearch") { engine.library.clearSearchHistory(); notice = "Ricerche cancellate." }
            actionRow("Esporta un backup", "Libreria, cronologia e (se vuoi) gli indirizzi degli addon, in un file.", "data.export") { dialog = { ExportDialog(engine, context, ::close) { notice = it } } }
            actionRow("Ripristina da un backup", "Un file creato da Aether per Android TV o per iPhone.", "data.import") { dialog = { ImportDialog(engine, context, ::close) { notice = it } } }
            actionRow("Ripristina le impostazioni", "Riporta le impostazioni ai valori iniziali (non tocca addon e libreria).", "data.resetSettings") { engine.settings.reset(); notice = "Impostazioni ripristinate." }
            actionRow("Cancella tutti i dati", "Addon, libreria, cronologia, impostazioni e chiavi.", "data.wipe") {
                dialog = { ConfirmDialog("Cancellare tutto?", "Verranno cancellati addon, libreria, cronologia, impostazioni e la chiave TorBox. Non si può annullare.", "Cancella tutto", {
                    scope.launch { engine.registry.removeAll(); engine.library.deleteAll(); engine.settings.reset(); engine.torBox.removeKey(); engine.cache.clear(); notice = "Tutti i dati sono stati cancellati." }; close()
                }, ::close) }
            }

            section("Informazioni")
            actionRow("Informazioni su Aether", "Versione ${BuildConfig.VERSION_NAME}, licenze e avvertenze.", "about.open") { onOpenAbout() }
        }
    }
    dialog?.invoke()
}

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

// MARK: Rows

private fun androidx.compose.foundation.lazy.LazyListScope.section(title: String) {
    item(key = "section-$title") { Text(title, style = MaterialTheme.typography.titleLarge, color = AetherColors.OnSurfaceMuted, modifier = Modifier.padding(top = 18.dp, bottom = 2.dp)) }
}

private fun androidx.compose.foundation.lazy.LazyListScope.toggleRow(title: String, description: String, checked: Boolean, tag: String, onChange: (Boolean) -> Unit) {
    item(key = tag) { SettingRow(title, description.ifBlank { null }, if (checked) "Sì" else "No", highlight = checked, tag = tag, onClick = { onChange(!checked) }) }
}

private fun androidx.compose.foundation.lazy.LazyListScope.choiceRow(title: String, value: String, tag: String, requester: FocusRequester? = null, onClick: () -> Unit) {
    item(key = tag) { SettingRow(title, null, value, tag = tag, requester = requester, onClick = onClick) }
}

private fun androidx.compose.foundation.lazy.LazyListScope.actionRow(title: String, description: String, tag: String, onClick: () -> Unit) {
    item(key = tag) { SettingRow(title, description.ifBlank { null }, null, tag = tag, onClick = onClick) }
}

@Composable
private fun SettingRow(title: String, description: String?, value: String?, highlight: Boolean = false, tag: String, requester: FocusRequester? = null, onClick: () -> Unit) {
    FocusSurface(onClick, Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp), focusScale = 1.015f, focusRequester = requester, testTag = tag) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium, color = AetherColors.OnBackground)
                description?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = AetherColors.OnSurfaceMuted, maxLines = 2, overflow = TextOverflow.Ellipsis) }
            }
            value?.let { Text(it, style = MaterialTheme.typography.titleMedium, color = if (highlight) LocalAccent.current else AetherColors.OnSurfaceMuted, modifier = Modifier.padding(start = 16.dp), maxLines = 1) }
        }
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
    val first = remember { FocusRequester() }
    AetherDialog("Esporta un backup", onDone, width = 700.dp) {
        Text("Il file contiene la tua libreria, la cronologia e le ricerche. Gli indirizzi degli addon possono contenere le tue chiavi personali: includili solo se il backup resta tuo.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
        TvButton(if (withUrls) "Includi gli indirizzi degli addon: sì" else "Includi gli indirizzi degli addon: no", { withUrls = !withUrls }, focusRequester = first, testTag = "export.urls")
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TvButton("Salva il backup", {
                scope.launch {
                    val message = withContext(Dispatchers.IO) {
                        try {
                            val urls = if (withUrls) engine.registry.handles(includeDisabled = true).map { it.transportUrl } else emptyList()
                            val text = BackupCodec.encode(engine.library.snapshot(), urls, withUrls, BuildConfig.VERSION_NAME)
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
            LazyColumn(Modifier.height(if (files.isEmpty()) 0.dp else minOf(files.size, 4) * 56.dp), verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(4.dp)) {
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
                TvButton("Unisci a quello che ho", { engine.library.merge(c.library); scope.launch { report(installAddons(engine, c) ?: "Backup unito alla libreria."); onDone() } }, primary = true, focusRequester = first, testTag = "import.merge")
                TvButton("Sostituisci tutto", { engine.library.replace(c.library); scope.launch { report(installAddons(engine, c) ?: "Libreria sostituita con il backup."); onDone() } }, testTag = "import.replace")
                TvButton("Indietro", { contents = null })
            }
            RequestFocusOnce(first)
        }
    }
}

private suspend fun installAddons(engine: AetherEngine, contents: BackupContents): String? {
    if (contents.addonUrls.isEmpty()) return null
    var ok = 0
    var failed = 0
    for (url in contents.addonUrls) { try { engine.registry.install(url); ok++ } catch (_: Throwable) { failed++ } }
    return "Backup ripristinato: $ok addon installati" + if (failed > 0) ", $failed non raggiungibili." else "."
}
