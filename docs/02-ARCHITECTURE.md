# FASE 2 — Architettura di Aether

## Principi

1. **Un motore indipendente dalla UI.** Tutta la logica che non dipende da UIKit/SwiftUI vive nel Swift Package `AetherCore`
   (solo Foundation; compila su iOS, macOS e — in linea di principio — Linux). Si testa con `swift test` senza simulatore.
2. **Interfacce sostituibili** (protocolli) per: rete (`HTTPClient`), segreti (`SecretStore`), persistenza (`JSONFileStore`),
   motore di riproduzione (`PlaybackEngine`), casting (`CastBackend`). Una sincronizzazione cloud non è implementata: nessuna interfaccia vuota è stata lasciata a fingere il contrario.
3. **Swift 5 language mode**, `async/await`, `actor` per lo stato condiviso, `@MainActor` solo nei view-model/UI.
4. **Nessuna dipendenza di terzi** salvo il Google Cast SDK (binario ufficiale, necessario per Chromecast / Android TV con Cast).
5. **Nessun codice eseguito da addon**: gli addon sono solo JSON dichiarativo trattato come input non fidato.

## Struttura del repository

```
Packages/AetherCore/            Swift Package (Foundation-only)
  Sources/AetherCore/
    Models/       Manifest, Meta, Stream, Subtitle, risposte tolleranti (LossyArray, FlexString)
    Net/          HTTPClient (URLSession), NetworkPolicy (SSRF/redirect/size/timeout), ResponseCache
    Addons/       AddonURL, ResourceURLBuilder, AddonClient, AddonRegistry (actor), AddonService (aggregazione), RequestPlanner
    Catalog/      CatalogPager (paginazione, filtri); i tipi/cataloghi effettivi li calcola RequestPlanner
    Search/       SearchService (concorrente, dedupe), LocalSearch
    Library/      LibraryStore (actor), progressi, cronologia, watchlist, Backup/merge
    Playback/     StreamAnalyzer (qualità/codec/compatibilità), StreamSelector, NextEpisode, Subtitle parser (SRT/VTT/ASS)
    Casting/      Compatibilità cast, UPnP/DLNA (descrizione, SOAP AVTransport, DIDL-Lite, SSDP)
    Downloads/    DownloadPlanner, DownloadStore (in Downloads.swift)
    Settings/     AppSettings (Codable, versionato)
    Diagnostics/  DiagnosticLog (ring buffer + redazione), Redactor
  Tests/AetherCoreTests/  Unit + integrazione contro un server addon di fixture (in-process)
App/Aether/                     App SwiftUI (iOS 17+, Liquid Glass su iOS 26+)
  App/            @main + AppDelegate (AetherApp.swift), composition root (AppEnvironment), AppRouter (deep link), AddonStore, LibraryModel
  DesignSystem/   Colori, tipografia, AetherGlass (Liquid Glass nativo con fallback materiale), componenti
  Features/       Home, Discover, Search, Library, Details, Player, Casting, Addons, Downloads, Settings (+ Informazioni e licenze)
  Services/       KeychainSecretStore, ImageLoader, NetworkMonitor, SettingsStore, BackupService, DownloadManager,
                  Playback/ (AVPlayerEngine, NowPlayingService, AudioSessionController), Casting/ (CastCoordinator, GoogleCastBackend, DLNABackend, SSDPScanner)
  Resources/      Assets.xcassets (icona, colori, logo), Info.plist, PrivacyInfo.xcprivacy
App/AetherTests/                Unit test che richiedono il bundle app (Keychain, view-model)
App/AetherUITests/              Test UI (XCUITest) contro il server di fixture
Tools/FixtureAddonServer/       Server Node di fixture (manifest, cataloghi, meta, stream, sottotitoli, addon lento/offline/invalido)
Scripts/                        Generazione icona, bootstrap
project.yml                     XcodeGen (sorgente di verità del progetto Xcode)
.github/workflows/ci.yml        macOS: swift test, build app, unit test e UI test su simulatore
```

## Flussi principali

**Installazione addon** → `AddonURL.parse` (normalizza `stremio://`, rifiuta schemi pericolosi) → `NetworkPolicy.validate`
(blocco IP privati/loopback/link-local salvo consenso rete locale) → `AddonClient.fetchManifest` (limite 1 MiB, timeout, redirect validati)
→ validazione manifest → deduplica per `id` *e* per URL di trasporto → `AddonRegistry.install` (l'URL completo, che può contenere chiavi API,
va nel `SecretStore`/Keychain; il JSON conserva solo host e id) → avviso "addon sconosciuto".

**Home / Scopri** → `DiscoverIndex` calcola dagli addon attivi i tipi e i cataloghi *effettivi* (nessuna categoria vuota) →
`CatalogSession` interroga gli addon in parallelo con `TaskGroup`, timeout per addon, cancellazione al cambio schermata,
cache con TTL (`cacheMaxAge`, `stale-if-error`), paginazione `skip`, stop quando la pagina è vuota o non porta ID nuovi.

**Dettaglio** → meta dal primo addon che dichiara `meta` per tipo/prefisso (fallback agli altri) → unione con gli item di catalogo →
stream da **tutti** gli addon compatibili in parallelo, risultati incrementali → `StreamAnalyzer` annota qualità/codec/lingua/compatibilità →
`StreamSelector` ordina e propone binge-group.

**Riproduzione** → `PlayerViewModel` (App) crea l'engine dietro il protocollo `PlaybackEngine` (oggi solo `AVPlayerEngine`: AVPlayer + `AVPlayerLayer` per PiP/AirPlay) →
snapshot di stato immutabili (`EngineSnapshot`) → `LibraryStore.recordProgress` (throttled) → fine episodio → `NextEpisodeResolver`.
Sottotitoli esterni: parser Core → cue → overlay SwiftUI con stile utente (AVPlayer non stila SRT esterni).

**Casting** → `CastCoordinator` possiede un'unica sessione remota e due backend dietro il protocollo `CastBackend`: Google Cast (SDK ufficiale, inizializzato
solo alla prima ricerca per non anticipare il permesso «Rete locale») e DLNA/UPnP (SOAP del Core, SSDP con socket BSD). AirPlay non è un backend: è il selettore di sistema
(`AVRoutePickerView`) più la riproduzione esterna di AVPlayer.
`CastCompatibility` blocca prima dell'invio le sorgenti che il ricevitore non può raggiungere (loopback/LAN/headers/codec).

## Persistenza e segreti

* Stato applicativo: file JSON versionati in *Application Support* (scrittura atomica, debounce, backup `.bak`), via `JSONFileStore`.
  Scelto al posto di SwiftData per: merge/backup deterministici, testabilità cross-platform in Core, assenza di macro/migrazioni opache.
* Impostazioni: `AppSettings` Codable versionato in `UserDefaults` (App) — tutte collegate a comportamento reale.
* Segreti (URL addon con chiavi): **Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
* Log: ring buffer con redazione di URL (solo host), query, header `Authorization`, token; esportazione già ripulita.

## Sicurezza (mappatura sul requisito §17)

| Requisito | Implementazione |
|---|---|
| Validazione URL / schemi | `AddonURL`, `NetworkPolicy.allowedSchemes` (`http`,`https`), rifiuto di `file`,`javascript`,`data`,… |
| Indirizzi locali/privati | `NetworkPolicy` (IPv4/IPv6 privati, loopback, link-local, CGNAT, `.local`, `localhost`) + risoluzione DNS (anti-rebinding best-effort) |
| Redirect | Ogni hop rivalidato; massimo 5; HTTPS→HTTP bloccato |
| Limiti di dimensione | Manifest 1 MiB, risposte catalogo/meta 8 MiB, sottotitoli 4 MiB (taglio in streaming) |
| TLS | Validazione di sistema; nessun override dei certificati |
| Nessuna chiave hardcoded / tracking | Nessuna analytics/crash reporting; PrivacyInfo dichiara nessun tracking |
| Nessun codice dagli addon | Solo JSON deserializzato |
| Cronologia | Solo locale; l'utente può cancellarla; nessun invio |

## Cosa è deliberatamente fuori ambito (dichiarato)

Account Stremio/Nuvio, Trakt/Simkl, debrid, torrent in-process, plugin JS, notifiche episodi in background, widget, motore MPV/VLC.
Vedi `docs/01-RESEARCH-MATRIX.md` §2 e `README.md` → "Stato reale".
