# FASE 1 — Ricerca tecnica: Stremio vs Nuvio

> Questo documento si basa sul **codice sorgente clonato** il 2026-10-19, non sulle descrizioni commerciali.
> Ogni riga indica dove la funzione è stata verificata. Dove non ho trovato evidenza nel codice lo scrivo.

| Progetto | Commit analizzato | Versione | Licenza | Stack |
|---|---|---|---|---|
| `Stremio/stremio-addon-sdk` | `ec4e0a4` (2026-09-23) | 1.6.10 | **MIT** | Node.js; contiene la documentazione normativa del protocollo (`docs/api`, `docs/protocol.md`, `docs/deep-links.md`, `docs/epg.md`) |
| `Stremio/stremio-core` | `c4806e8` (2026-10-12) | 0.1.0 (`SCHEMA_VERSION` 25) | **MIT** | Rust (modelli, runtime a effetti, trasporto addon, libreria, profilo) |
| `Stremio/stremio-web` | `bb2405c` (2026-10-14) | 5.0.0-beta.42 | **GPL-2.0** | React + core in WASM (Web Worker) |
| `NuvioMedia/NuvioMobile` | `324afcf` (2026-10-18) | 0.6.2 (iOS `Version.xcconfig`) | **GPL-3.0** | Kotlin Multiplatform + Compose Multiplatform; iOS con bridge Swift e **libmpv** (fork `NuvioMedia/MPVKit`) |

Fonti principali lette: `stremio-addon-sdk/docs/api/responses/{manifest,meta,stream,subtitles,addon_catalog}.md`,
`docs/api/requests/*`, `stremio-core/src/types/{addon,resource,library,profile,api}`, `src/addon_transport/http_transport`,
`src/constants.rs`, `stremio-web/src/routes/*`, `NuvioMobile/composeApp/src/{commonMain,iosMain,iosFull,iosAppStore}`, `iosApp/`.

---

## 1. Il protocollo addon (comune a entrambi) — ciò che Aether deve implementare

Verificato in `docs/protocol.md`, `manifest.md`, `meta.md`, `stream.md`, `subtitles.md`, `defineCatalogHandler.md` e in
`stremio-core/src/types/addon/{manifest,request,response}.rs` e `http_transport.rs`.

* **Trasporto HTTP**: `GET {base}/manifest.json`; risorse `GET {base}/{resource}/{type}/{id}.json` e, con parametri extra,
  `GET {base}/{resource}/{type}/{id}/{k=v&k2=v2}.json`. Tutti i componenti sono codificati con *URI component encoding*
  (tutto tranne `A-Za-z0-9-_.!~*'()`, vedi `URI_COMPONENT_ENCODE_SET` in `constants.rs`). Il core sostituisce `/manifest.json`
  nella stringa dell'URL, quindi un'eventuale query (`?config=…`) viene **preservata** dopo `.json` (Nuvio fa lo stesso in `AddonTransportUrls.kt`).
* **Trasporto legacy** (`…/stremio/v1`, JSON-RPC v1/v2) e menzione di IPFS nei doc: il core implementa solo HTTP + legacy
  (`addon_transport/http_transport/legacy`). **Aether implementa solo HTTP(S)**; legacy/IPFS sono dichiarati non supportati.
* **Risorse**: `catalog`, `meta`, `stream`, `subtitles`, `addon_catalog` (+ EPG nativo: catalogo `tv` con extra `date` e
  `behaviorHints.epgProvider`, risposta `metasDetailed`).
* **Manifest**: `id`, `version`, `name`, `description`, `types`, `resources` (stringa **oppure** `{name, types?, idPrefixes?}`),
  `idPrefixes`, `catalogs[{type,id,name,extra[{name,isRequired,options,optionsLimit}]}]`, `addonCatalogs`, `config[]`,
  `behaviorHints{adult,p2p,configurable,configurationRequired,epgProvider}`, `logo`, `background`, `contactEmail`.
  Esiste anche il formato "short" legacy per gli extra (`extraSupported`/`extraRequired`).
* **Regole di instradamento** (`Manifest::is_resource_supported`): per `catalog` conta solo `catalogs[]` (type+id+extra);
  per le altre risorse il tipo deve essere nei `types` della risorsa (o del manifest se la risorsa è una stringa) e l'id deve
  iniziare con uno dei `idPrefixes` (vuoti/assenti = tutti).
* **Extra** (`ManifestCatalog::is_extra_supported`): ogni extra richiesto deve essere dichiarato e ogni extra `isRequired` deve essere presente.
  `search`, `genre`, `skip` (paginazione, pagina standard = 100), `date` (EPG), `videoHash`/`videoSize`/`filename` per i sottotitoli.
* **Risposte tolleranti**: il core scarta gli elementi non validi di un array invece di fallire tutta la risposta (`VecSkipError`),
  accetta `null`, `title`↔`description`, `stream`↔`streams`; campi cache `cacheMaxAge`, `staleRevalidate`, `staleError`.
* **Stream**: una tra `url` | `ytId` | `infoHash`(+`fileIdx`,`sources`) | `externalUrl` | `nzbUrl` | `rarUrls` | `zipUrls` | `7zipUrls` | `tgzUrls` | `tarUrls` | `playerFrameUrl`;
  `name`, `description`/`title`, `subtitles[]`, `behaviorHints{countryWhitelist,notWebReady,bingeGroup,proxyHeaders{request,response},videoHash,videoSize,filename}`.
* **Video** (episodi): `id`, `title`/`name`, `released`, `season`, `episode`, `thumbnail`, `overview`, `streams`; l'id episodio Cinemeta è `{imdb}:{season}:{episode}`.
* **Deep link** (`docs/deep-links.md`): `stremio://host/…/manifest.json` (→ `https://`), `stremio:///detail/{type}/{id}[/{videoId}]`, `stremio:///search?search=`, `stremio:///discover/{addonUrl}/{type}/{catalogId}?genre=`.

## 2. Matrice comparativa delle funzioni

Legenda: ✅ verificato nel codice · ◐ parziale/dipende dalla build · ✖ non trovato · ⛔ non riproducibile su iOS in modo nativo.

### 2.1 Funzioni presenti in entrambi

| Funzione | Stremio (core/web) | Nuvio (Kotlin) | Evidenza | In Aether |
|---|---|---|---|---|
| Addon Stremio (HTTP) | ✅ | ✅ | `addon_transport/http_transport`; `features/addons/{AddonManifestParser,AddonTransportUrls,AddonRepository}.kt` | **Sì** (FASE 4) |
| Cataloghi con filtri/extra, ricerca, skip | ✅ `models/catalog_with_filters.rs` | ✅ `features/catalog`, `features/search` | idem | **Sì** |
| Pagina dettaglio (meta, episodi, stream) | ✅ `models/meta_details.rs`, `routes/MetaDetails` | ✅ `features/details` (40 file) | idem | **Sì** |
| Libreria / watchlist / progressi / "continua a guardare" | ✅ `types/library`, `models/continue_watching_preview.rs` | ✅ `features/library`, `watchprogress`, `watched` | idem | **Sì** (locale) |
| Sottotitoli da addon + stile | ✅ `types/profile/settings.rs` (font, colore, contorno, offset, opacità, ASS) | ✅ `features/player` | idem | **Sì** (overlay proprio) |
| Scelta lingua audio/sottotitoli preferita | ✅ `audio_language`, `subtitles_language` | ✅ | idem | **Sì** |
| Autoplay episodio successivo (binge) | ✅ `binge_watching`, `bingeGroup` | ✅ `features/streams/StreamAutoPlay*` | idem | **Sì** |
| Notifiche nuovi episodi / calendario | ✅ `models/calendar.rs`, `ctx/update_notifications.rs` | ✅ `features/notifications` | idem | **Non ancora** (richiede polling in background; dichiarato) |
| Cronologia ricerche | ✅ `types/search_history` | ✅ `search/SearchHistoryRepository.kt` | idem | **Sì** |
| Deep link `stremio://` | ✅ `deep_links` | ✅ `Info.plist` registra `nuvio` e `stremio` | idem | **Sì** |
| Account + sincronizzazione cloud | ✅ API `api.strem.io` (`types/api/request.rs`) | ✅ Supabase (`build.gradle.kts`, `core/sync`) | idem | **No** — vedi §5 |
| Integrazione Trakt | ✅ `ctx/update_trakt_addon.rs` | ✅ `features/trakt` (25 file) | idem | **Non ancora** |

### 2.2 Solo Stremio

| Funzione | Evidenza | Note per Aether |
|---|---|---|
| **Streaming server locale** (127.0.0.1:11470): torrent→HTTP, archivi rar/zip/7z/tar/tgz, nzb, transcodifica, conversione codifica sottotitoli | `STREAMING_SERVER_URL`, `types/streaming_server`, `resource/stream.rs` | ⛔ Su iOS non si può eseguire un server Node in background. Alternativa: URL di un server Stremio esterno configurabile (sperimentale, off) — §4 |
| Trasporto addon **legacy** (`/stremio/v1`) | `http_transport/legacy` | Non supportato (dichiarato) |
| Account Stremio, datastore (`datastoreGet/Put`), `addonCollectionGet/Set`, export dati GDPR | `types/api/request.rs`, `models/data_export.rs` | Non integrato: API interna non pubblicata come contratto stabile |
| **Skip intro/outro** (`SkipGaps`, premium) e *seek log* | `APIRequest::SkipGaps`, `SeekLog` | Non implementato (richiede account premium) |
| **Native EPG / Live TV** (`epgProvider`, `metasDetailed`) | `docs/epg.md`, `models/live_tv_guide.rs` | **Sì** (lettura guida + canali) in forma base |
| Rating "likes" | `USER_LIKES_API_URL` | No |
| Chromecast (web sender) | `stremio-web/src/services/Chromecast`, `routes/Player/CastDevicesMenu` | **Sì**, ma nativo (SDK iOS) |
| Gamepad, scorciatoie tastiera, PWA, 50+ lingue | `services/GamepadNavigation`, `routes/Settings/Shortcuts` | N/A su iPhone |

### 2.3 Solo Nuvio

| Funzione | Evidenza | Note per Aether |
|---|---|---|
| **Plugin proprietari** (scraper JS eseguiti in QuickJS; repository con manifest `scrapers[]`) | `features/plugins/*`, `vendor/quickjs-kt`, `iosFull/…/PluginRuntime.ios.kt` | **Non compatibili con gli addon Stremio** (formato e runtime diversi). La build "App Store" di Nuvio li **disattiva** (`AppFeaturePolicy.pluginsEnabled=false` in `iosAppStore/`). Aether **non esegue codice di terze parti** (requisito §17): non implementato |
| P2P/torrent via **TorrServer** embedded | `vendor/TorrServer`, `features/p2p`, `p2pEnabled` (solo build "full") | Non implementato |
| Debrid (Torbox, Premiumize, RealDebrid) e *cloud library* | `features/debrid`, `features/cloud` | Non implementato |
| Altri tracker: Simkl, MDBList; metadati TMDB | `features/{simkl,mdblist,tmdb}` | Non implementato (TMDB richiederebbe chiave utente) |
| Profili con PIN, collezioni/cartelle personalizzate, watch party, server Emby/Jellyfin | `features/{profiles,collection,party,servers}` | Non implementato |
| Shuffle episodio casuale, trailer in-app, parental guide, skip segmenti, *subtitle auto-sync* | `features/{shuffle,trailer,player}`, `docs/subtitle-autosync.md` | Non implementato. (L'auto-sync è **solo Android/ExoPlayer**: "iOS continues using existing behavior") |
| Download | `features/downloads`, `iosMain/…/DownloadsPlatformDownloader.ios.kt` | **Sì**: URLSession in background; escludono `.m3u8` e `.torrent` (`DownloadsRepository.kt:570`) — stessa regola in Aether |
| Player iOS | **libmpv** (MPVKit) + PiP + NowPlaying (`iosApp/Player/*.swift`) | Aether: AVPlayer primario (§3) |
| App updater, icone alternative, 26 lingue | `features/updater`, `settings/AppIcon*`, `composeResources/values-*` | Non implementato |
| Account Nuvio (Supabase) | `build.gradle.kts` (`NUVIO_SUPABASE_URL/ANON_KEY` da config) | Non integrabile: backend privato del progetto |

### 2.4 Disponibili solo su determinate piattaforme/versioni

| Funzione | Dettaglio verificato |
|---|---|
| Nuvio *subtitle auto-sync* | Solo Android ExoPlayer (`docs/subtitle-autosync.md`) |
| Nuvio plugin, P2P, trailer in-app, server custom, IMDb logo | Solo flavor `iosFull`/`androidFull`. **Non** in `iosAppStore`/`androidPlaystore` (`AppFeaturePolicy.ios.kt`) |
| Nuvio distribuzione iOS | Solo AltStore/SideStore (README), non App Store |
| Stremio Skip-gaps | Richiede account premium (`SkipGapsRequest` commento) |
| Stremio streaming server | Desktop/Android/server; non esiste per iOS in questo codice |
| Stremio Chromecast | Solo web (`stremio-web`) |

### 2.5 Funzioni non riproducibili direttamente su iOS e alternative adottate

| Funzione | Perché non è diretta | Alternativa in Aether |
|---|---|---|
| Torrent / NZB / archivi | Nessun server locale persistente; BitTorrent in-process non incluso | Mostrati come "non riproducibili"; opzione sperimentale "server di streaming esterno" che mappa `infoHash` → `{server}/{hash}/{fileIdx}` (stessa regola di `resource/stream.rs`), **disattivata di default** e non verificata contro un server reale |
| MKV/AVI/WebM/FLV, DASH, ASS/PGS incorporati | AVPlayer non li supporta | Rilevamento preventivo + messaggio; interfaccia `PlaybackEngine` per un motore alternativo (MPVKit/VLCKit) **non incluso** (§3 licenze/dimensioni) |
| Plugin JS di Nuvio | Esecuzione di codice remoto non fidato | Non implementato; si usano solo addon dichiarativi |
| Multicast SSDP (DLNA) | Richiede entitlement `com.apple.developer.networking.multicast` approvato da Apple | Aggiunta manuale del renderer per URL; SSDP opzionale se l'entitlement è presente |
| YouTube `ytId` | Nessun player YouTube integrato | Apertura nel browser/app di sistema |
| Volume di sistema | Nessuna API pubblica per impostarlo | Pulsanti hardware + `MPVolumeView` (slider di sistema) |
| Riproduzione in background (video) | iOS sospende la grafica; consentito solo audio e PiP | Audio background mode + Picture-in-Picture |

## 3. Licenze e compatibilità delle dipendenze

| Componente | Licenza | Decisione | Motivazione |
|---|---|---|---|
| stremio-addon-sdk (docs) | MIT | **Usato come specifica** | Nessun codice copiato; implementazione indipendente |
| stremio-core | MIT | **Non incluso** come libreria; usato come riferimento semantico | È Rust: servirebbe cross-compilare (`aarch64-apple-ios`), esporre FFI e implementare `Env` in Swift. Complessità/size sproporzionate e non verificabili senza macchina macOS. Il comportamento è replicato in Swift e attribuito in `NOTICE` |
| stremio-web | **GPL-2.0** | **Nessun codice/asset/branding riutilizzato** | Copyleft: contaminerebbe l'intera app. Letto solo per ricerca funzionale |
| NuvioMobile | **GPL-3.0** | **Nessun codice/asset/branding riutilizzato** | Idem. Inoltre la licenza GPL è incompatibile con i termini dell'App Store e con il Google Cast SDK proprietario |
| MPVKit (upstream `mpvkit/MPVKit`) | **LGPL-3.0** (variante `-GPL` con samba); contiene FFmpeg/mpv/libass | **Non incluso** | Il README stesso dichiara "only suitable for learning… not maintained frequently; for production consider AetherEngine". LGPL su iOS richiede di consentire il re-link; impatto sulle dimensioni di decine di MB; non testabile qui. Resta una *estensione futura* dietro `PlaybackEngine` |
| VLCKit | LGPL-2.1+ | Non incluso | Stesse considerazioni (dimensione ~100 MB+, re-link) |
| **Google Cast iOS SDK** `googlecast/google-cast-ios-sdk` 4.8.6 | Wrapper SPM Apache-2.0; **binario proprietario** sotto i termini Google Cast SDK | **Incluso** via SPM (`GoogleCastDynamic`, non entrambi i prodotti), iOS ≥ 16, dipende da `google/gtm-session-fetcher` (Apache-2.0) | Documentazione ufficiale richiede `NSBonjourServices` (`_googlecast._tcp`, `_<appId>._googlecast._tcp`) e `NSLocalNetworkUsageDescription`. Il pacchetto non è open source: la distribuzione binaria è consentita dai termini Google, ma va dichiarato in `NOTICE` |
| Framework Apple (SwiftUI, AVFoundation, AVKit, AVRouting, Network, MediaPlayer, Security, CryptoKit) | Termini SDK Apple | Usati | Nessuna dipendenza di terzi per il resto dell'app |
| XcodeGen | MIT | Solo strumento di build | Non distribuito nell'IPA |

**Obblighi di attribuzione**: `NOTICE` e `docs/03-LICENSES.md` elencano Google Cast SDK, gtm-session-fetcher e il riferimento al protocollo MIT; l'app
espone la pagina «Informazioni e licenze» (Altro → Informazioni e licenze).

## 4. Limiti tecnici iOS rilevanti (verificati/dichiarati)

* **App Transport Security**: `URLSession` blocca HTTP in chiaro verso host pubblici. Aether imposta `NSAllowsLocalNetworking` (addon in LAN) e
  `NSAllowsArbitraryLoadsInMediaAndWebContent` (solo caricamenti **media** via AVFoundation). Un addon pubblico servito in `http://` quindi **non** si installa:
  messaggio dedicato. Questo è il compromesso scelto per "gestire addon HTTP legacy senza indebolire inutilmente la sicurezza".
* **Rete locale**: scoperta Cast/Bonjour e addon in LAN richiedono la finestra di consenso "Rete locale" (`NSLocalNetworkUsageDescription`).
* **Entitlement multicast** (SSDP/DLNA): da richiedere ad Apple; senza, scoperta SSDP non funziona → aggiunta manuale.
* **Picture-in-Picture** richiede `AVPlayerLayer` e capability *Audio, AirPlay and Picture in Picture*.
* **Orientamento, luminosità**: gestiti dall'app; volume solo tramite sistema.
* **Sideload/IPA firmato**: richiede un Apple Developer account; non è producibile in questo ambiente (§README).

## 5. Account e sincronizzazione — decisione

Le uniche API "ufficiali compatibili" esistenti sono quelle del backend Stremio (`api.strem.io`) e del backend Supabase di Nuvio.
Il codice mostra come **il client ufficiale** le usa, ma **non esiste una documentazione pubblica di contratto stabile per client di terze parti**,
e l'autenticazione richiederebbe di inserire la password Stremio in un'app non ufficiale. Non le integro.
Aether implementa invece: libreria locale persistente, **backup/ripristino/merge** con risoluzione dei conflitti (ultimo-modificato + tombstone),
esportazione JSON, e un'interfaccia `SyncProvider` per un backend opzionale futuro. **Nessuna sincronizzazione multi-dispositivo è promessa.**
