package app.aether.tv.ui.screens.addons

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Extension
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.aether.core.addons.AddonInstallPreview
import app.aether.core.addons.AddonInstallWarning
import app.aether.core.addons.InstalledAddon
import app.aether.core.addons.KnownAddons
import app.aether.core.addons.RequestPlanner
import app.aether.core.net.AddonError
import app.aether.tv.Session
import app.aether.tv.aether
import app.aether.tv.ui.components.AetherDialog
import app.aether.tv.ui.components.Badge
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.LoadingState
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.components.TvIconButton
import app.aether.tv.ui.components.TvTextField
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAccent
import kotlinx.coroutines.launch
import fi.iki.elonen.NanoHTTPD

@Composable
fun AddonsScreen(initialInput: String?, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val engine = context.aether
    val scope = rememberCoroutineScope()
    val revision by engine.registry.revision.collectAsStateWithLifecycle()
    var addons by remember { mutableStateOf<List<InstalledAddon>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(revision) { addons = engine.registry.all(); loaded = true }

    var addDialog by remember { mutableStateOf(initialInput != null || Session.pendingAddonInput != null) }
    var prefill by remember { mutableStateOf(initialInput ?: Session.pendingAddonInput.orEmpty()) }
    var catalogsOf by remember { mutableStateOf<InstalledAddon?>(null) }
    var renaming by remember { mutableStateOf<InstalledAddon?>(null) }
    var removing by remember { mutableStateOf<InstalledAddon?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var refreshing by remember { mutableStateOf(false) }
    var remoteAddress by remember { mutableStateOf<String?>(null) }
    val remoteServer = remember { AddonRemoteServer(engine.registry) }
    DisposableEffect(remoteServer) { onDispose { runCatching { remoteServer.stop() } } }
    val addButton = remember { FocusRequester() }
    LaunchedEffect(Unit) { Session.pendingAddonInput = null }
    if (!addDialog) RequestFocusOnce(addButton, loaded)

    Column(modifier.fillMaxSize().padding(top = AetherDimens.ScreenVertical)) {
        Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("Addon", style = MaterialTheme.typography.headlineLarge, color = AetherColors.OnBackground, modifier = Modifier.padding(end = 16.dp))
            TvButton("Aggiungi addon", { prefill = ""; addDialog = true }, icon = Icons.Filled.Add, primary = true, focusRequester = addButton, testTag = "addons.add")
            TvButton(if (remoteAddress == null) "Aggiungi dal telefono" else "Chiudi accesso telefono", {
                if (remoteAddress != null) { runCatching { remoteServer.stop() }; remoteAddress = null }
                else try { remoteServer.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false); remoteAddress = remoteServer.localUrl ?: "IP della TV:8765" }
                catch (e: Exception) { message = "Non riesco ad aprire l’accesso locale: " + (e.message ?: "porta occupata"); remoteAddress = null }
            }, testTag = "addons.phone")
            if (addons.isNotEmpty()) TvButton(if (refreshing) "Aggiorno…" else "Aggiorna tutti", {
                scope.launch { refreshing = true; val outcomes = engine.registry.refreshAll(); refreshing = false
                    message = outcomes.count { it.error != null }.let { failed -> if (failed == 0) "Addon aggiornati." else "$failed addon non hanno risposto." } }
            }, icon = Icons.Filled.Refresh, enabled = !refreshing, testTag = "addons.refreshAll")
        }
        message?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal, vertical = 6.dp)) }
        remoteAddress?.let { address ->
            Column(Modifier.fillMaxWidth().padding(horizontal = AetherDimens.ScreenHorizontal, vertical = 8.dp).background(AetherColors.Surface, RoundedCornerShape(14.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Aggiungi addon dal telefono", style = MaterialTheme.typography.titleMedium, color = AetherColors.OnBackground)
                Text("Collega il telefono alla stessa Wi-Fi della TV e apri questo indirizzo nel browser:", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
                Text(address, style = MaterialTheme.typography.titleLarge, color = LocalAccent.current)
                Text("La pagina è temporanea e protetta da un token. Rimani in questa schermata finché installi l’addon.", style = MaterialTheme.typography.bodySmall, color = AetherColors.OnSurfaceMuted)
            }
        }
        if (loaded && addons.isEmpty()) {
            EmptyState(
                "Nessun addon installato",
                "Un addon è un servizio che fornisce cataloghi o sorgenti a Aether, e lo scegli tu. Incolla l'indirizzo del suo manifest (finisce con /manifest.json), oppure parti da Cinemeta, il catalogo di base di Stremio.",
                Modifier.fillMaxWidth().padding(top = 24.dp),
            ) { TvButton("Aggiungi Cinemeta", { prefill = KnownAddons.CINEMETA_MANIFEST_URL; addDialog = true }, testTag = "addons.addCinemeta") }
        } else {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 14.dp, bottom = 48.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                items(addons.size, key = { addons[it].id }) { index ->
                    val addon = addons[index]
                    AddonCard(
                        addon, canUp = index > 0, canDown = index < addons.lastIndex,
                        onToggle = { scope.launch { engine.registry.setEnabled(!addon.isEnabled, addon.id) } },
                        onUp = { scope.launch { engine.registry.move(addon.id, -1) } },
                        onDown = { scope.launch { engine.registry.move(addon.id, 1) } },
                        onCatalogs = { catalogsOf = addon },
                        onRefresh = { scope.launch { val outcome = engine.registry.refresh(addon.id); message = outcome?.error ?: "«${addon.displayName}» aggiornato (versione ${outcome?.newVersion ?: addon.manifest.version})." } },
                        onRename = { renaming = addon },
                        onRemove = { removing = addon },
                        onConfigure = {
                            scope.launch {
                                val url = engine.registry.transportUrl(addon.id)?.replace("/manifest.json", "/configure")
                                val opened = url != null && runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.isSuccess
                                if (!opened) message = "Questa TV non ha un browser per aprire la pagina di configurazione. Configura l'addon da un altro dispositivo e inserisci qui il nuovo indirizzo."
                            }
                        },
                    )
                }
            }
        }
    }

    if (addDialog) AddAddonDialog(prefill, onDismiss = { addDialog = false }, onInstalled = { name -> addDialog = false; message = "«$name» installato." })
    catalogsOf?.let { addon -> CatalogsDialog(addon) { catalogsOf = null } }
    renaming?.let { addon ->
        var name by remember { mutableStateOf(addon.nameOverride ?: addon.manifest.name) }
        val field = remember { FocusRequester() }
        AetherDialog("Rinomina l'addon", { renaming = null }) {
            TvTextField(name, { name = it }, "Nome", focusRequester = field, onImeAction = { scope.launch { engine.registry.setNameOverride(name, addon.id) }; renaming = null })
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton("Salva", { scope.launch { engine.registry.setNameOverride(name, addon.id) }; renaming = null }, primary = true)
                TvButton("Nome originale", { scope.launch { engine.registry.setNameOverride(null, addon.id) }; renaming = null })
                TvButton("Annulla", { renaming = null })
            }
            RequestFocusOnce(field)
        }
    }
    removing?.let { addon ->
        val no = remember { FocusRequester() }
        AetherDialog("Rimuovere «${addon.displayName}»?", { removing = null }) {
            Text("L'addon e il suo indirizzo vengono cancellati da questo dispositivo. Potrai aggiungerlo di nuovo quando vuoi.", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton("Rimuovi", { scope.launch { engine.registry.uninstall(addon.id) }; removing = null }, primary = true, testTag = "addons.confirmRemove")
                TvButton("Annulla", { removing = null }, focusRequester = no)
            }
            RequestFocusOnce(no)
        }
    }
}

@Composable
private fun AddonCard(
    addon: InstalledAddon, canUp: Boolean, canDown: Boolean,
    onToggle: () -> Unit, onUp: () -> Unit, onDown: () -> Unit, onCatalogs: () -> Unit, onRefresh: () -> Unit, onRename: () -> Unit, onRemove: () -> Unit, onConfigure: () -> Unit,
) {
    val manifest = addon.manifest
    Column(
        Modifier.fillMaxWidth().background0().padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Filled.Extension, null, tint = if (addon.isEnabled) LocalAccent.current else AetherColors.OnSurfaceFaint)
            Text(addon.displayName, style = MaterialTheme.typography.titleLarge, color = if (addon.isEnabled) AetherColors.OnBackground else AetherColors.OnSurfaceFaint, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            Badge("v${manifest.version}")
            if (addon.isOfficial) Badge("Ufficiale", color = LocalAccent.current, contentColor = AetherColors.Background)
            if (!addon.isEnabled) Badge("Disattivato", color = AetherColors.Warning, contentColor = AetherColors.Background)
            if (addon.needsReinstall) Badge("Da reinstallare", color = AetherColors.Danger, contentColor = AetherColors.Background)
            if (addon.isLocalNetwork) Badge("Rete locale")
        }
        manifest.description?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted, maxLines = 2, overflow = TextOverflow.Ellipsis) }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(addon.host, style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceFaint)
            for (item in manifest.capabilitySummary) Badge(resourceLabel(item))
            val feeds = manifest.catalogs.size
            if (feeds > 0) Badge("$feeds cataloghi")
        }
        addon.lastError?.let { Text("Ultimo errore: $it", style = MaterialTheme.typography.labelMedium, color = AetherColors.Danger, maxLines = 2) }
        if (addon.needsReinstall) Text("L'indirizzo di questo addon non è più sul dispositivo (ripristino di un backup o dati cancellati): rimuovilo e aggiungilo di nuovo.", style = MaterialTheme.typography.labelMedium, color = AetherColors.Warning)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 6.dp)) {
            item { TvChip(if (addon.isEnabled) "Disattiva" else "Attiva", false, onToggle, testTag = "addon.toggle") }
            if (canUp) item { TvIconButton(Icons.Filled.KeyboardArrowUp, "Sposta su (più priorità)", onUp, size = 38.dp, testTag = "addon.up") }
            if (canDown) item { TvIconButton(Icons.Filled.KeyboardArrowDown, "Sposta giù", onDown, size = 38.dp, testTag = "addon.down") }
            if (manifest.catalogs.isNotEmpty()) item { TvChip("Cataloghi", false, onCatalogs, testTag = "addon.catalogs") }
            if (manifest.behaviorHints.configurable) item { TvChip("Configura", false, onConfigure) }
            item { TvChip("Aggiorna", false, onRefresh) }
            item { TvChip("Rinomina", false, onRename) }
            item { TvChip("Rimuovi", false, onRemove, testTag = "addon.remove") }
        }
    }
}

private fun Modifier.background0(): Modifier =
    this.clip(RoundedCornerShape(18.dp)).background(AetherColors.Surface)

private fun resourceLabel(name: String) = when (name) {
    "catalog" -> "Cataloghi"; "meta" -> "Dettagli"; "stream" -> "Sorgenti"; "subtitles" -> "Sottotitoli"; "addon_catalog" -> "Addon"; else -> name
}

@Composable
private fun AddAddonDialog(initial: String, onDismiss: () -> Unit, onInstalled: (String) -> Unit) {
    val engine = LocalContext.current.aether
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf(initial) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var preview by remember { mutableStateOf<AddonInstallPreview?>(null) }
    val field = remember { FocusRequester() }
    val install = remember { FocusRequester() }

    fun check() {
        if (working) return
        scope.launch {
            working = true; error = null
            try { preview = engine.registry.preview(text) } catch (e: Throwable) { if (e is kotlin.coroutines.cancellation.CancellationException) throw e; error = AddonError.from(e).message }
            working = false
        }
    }
    LaunchedEffect(Unit) { if (initial.isNotBlank()) check() }

    AetherDialog(if (preview == null) "Aggiungi un addon" else "Installare questo addon?", onDismiss, width = 760.dp) {
        val p = preview
        if (p == null) {
            Text("Incolla o scrivi l'indirizzo del manifest dell'addon (https://…/manifest.json). Anche gli indirizzi stremio:// vanno bene.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
            TvTextField(text, { text = it; error = null }, "Indirizzo dell'addon", placeholder = "https://v3-cinemeta.strem.io/manifest.json", keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go, onImeAction = ::check, focusRequester = field, testTag = "addons.url")
            error?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.Danger) }
            if (working) LoadingState("Controllo l'addon…")
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton("Controlla", ::check, primary = true, enabled = !working && text.isNotBlank(), testTag = "addons.check")
                TvButton("Usa Cinemeta", { text = KnownAddons.CINEMETA_MANIFEST_URL }, testTag = "addons.useCinemeta")
                TvButton("Annulla", onDismiss)
            }
            RequestFocusOnce(field)
        } else {
            val m = p.manifest
            Text("${m.name}  ·  v${m.version}", style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground)
            m.description?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted, maxLines = 3, overflow = TextOverflow.Ellipsis) }
            Text("Fornisce: " + m.capabilitySummary.joinToString(", ") { resourceLabel(it) } + if (m.catalogs.isNotEmpty()) " (${m.catalogs.size} cataloghi)" else "", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnBackground)
            if (m.types.isNotEmpty()) Text("Tipi: " + m.types.joinToString(", ") { RequestPlanner.friendlyTypeName(it) }, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
            p.existing?.let { Text("È già installato: continuando viene aggiornato.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.Warning) }
            for (warning in p.warnings) Text(
                when (warning) {
                    AddonInstallWarning.UnknownAddon -> "Addon di terze parti: Aether non lo ha verificato e non ne controlla i contenuti. Installa solo ciò di cui ti fidi."
                    AddonInstallWarning.P2p -> "Questo addon usa il peer-to-peer (torrent)."
                    AddonInstallWarning.Adult -> "Questo addon dichiara contenuti per adulti."
                    AddonInstallWarning.LocalNetwork -> "L'indirizzo è sulla tua rete locale."
                },
                style = MaterialTheme.typography.bodySmall, color = AetherColors.Warning,
            )
            error?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.Danger) }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton(if (working) "Installo…" else "Installa", {
                    scope.launch {
                        working = true
                        try { val installed = engine.registry.install(p); onInstalled(installed.displayName) } catch (e: Throwable) { if (e is kotlin.coroutines.cancellation.CancellationException) throw e; error = AddonError.from(e).message }
                        working = false
                    }
                }, primary = true, enabled = !working, focusRequester = install, testTag = "addons.install")
                TvButton("Indietro", { preview = null })
            }
            RequestFocusOnce(install)
        }
    }
}

@Composable
private fun CatalogsDialog(addon: InstalledAddon, onDismiss: () -> Unit) {
    val engine = LocalContext.current.aether
    val scope = rememberCoroutineScope()
    var current by remember { mutableStateOf(addon) }
    val first = remember { FocusRequester() }
    AetherDialog("Cataloghi di ${addon.displayName}", onDismiss, width = 700.dp) {
        Text("Scegli quali cataloghi compaiono nella Home e in Scopri.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
        LazyColumn(Modifier.height(320.dp), verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(4.dp)) {
            items(current.manifest.catalogs.size) { i ->
                val catalog = current.manifest.catalogs[i]
                val visible = current.isCatalogVisible(catalog)
                FocusSurface({
                    scope.launch { engine.registry.setCatalogVisible(!visible, catalog.key, current.id); current = engine.registry.addon(current.id) ?: current }
                }, Modifier.fillMaxWidth().height(48.dp), focusRequester = if (i == 0) first else null) {
                    Row(Modifier.padding(horizontal = 14.dp).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("${catalog.name} · ${RequestPlanner.friendlyTypeName(catalog.type)}" + if (!catalog.isPlainFeed) "  (solo ricerca)" else "", Modifier.weight(1f).padding(vertical = 12.dp), style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (visible) Icon(Icons.Filled.Check, "Visibile", tint = LocalAccent.current)
                    }
                }
            }
        }
        TvButton("Fatto", onDismiss, primary = true)
        RequestFocusOnce(first)
    }
}
