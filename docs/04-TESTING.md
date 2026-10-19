# Test: strategia, scenari e risultati reali

Questo documento dice **cosa è stato eseguito davvero** e cosa no. Nessun test hardware è dichiarato superato se non è stato eseguito su hardware reale.

## Livelli

| Livello | Dove | Come si esegue | Dove gira |
|---|---|---|---|
| Unit + integrazione del nucleo | `Packages/AetherCore/Tests` | `swift test` | CI (macOS), Linux in teoria |
| Unit dell'app (impostazioni, router, Portachiavi, casting con ricevitori finti, cache immagini, backup) | `App/AetherTests` | `xcodebuild test -only-testing:AetherTests` | CI, simulatore iPhone |
| UI (XCUITest) contro addon di fixture | `App/AetherUITests` | `xcodebuild test -only-testing:AetherUITests` | CI, simulatore iPhone |

## Fixture e server controllati

* `Tools/FixtureAddonServer/server.js` — addon Stremio di prova (Node ≥ 18, nessuna dipendenza): manifest valido, manifest incompleto, pagina HTML al posto del manifest,
  cataloghi film/serie con ricerca e paginazione, meta con episodi, sorgenti MP4 (due qualità), titolo con sole sorgenti MKV/torrent, titolo senza sorgenti,
  sottotitoli SRT e VTT, poster generati, MP4 con supporto `Range`, interruttore **offline** (`/__control/offline?on=1`) e registro delle richieste.
* `Tools/MakeFixtureVideo.swift` — genera con AVAssetWriter un MP4 H.264 valido da 150 s (nessun file binario nel repository).
* `Packages/AetherCore/Tests/AetherCoreTests/Fixtures` — manifest e risposte JSON "sporche" (campi mancanti, numeri come stringhe, elementi malformati), SRT/VTT/ASS in varie codifiche.
* Nessun test dipende da addon pubblici.

L'app, avviata dai test UI con `-AETHER_UITEST`, usa storage isolato per sessione, il Portachiavi reale con un servizio dedicato, consente gli indirizzi loopback
(solo in questa modalità) e accetta `-AETHER_UITEST_SETTINGS`, `-AETHER_UITEST_OPENURL`, `-AETHER_UITEST_RESET` (vedi `UITestHooks` in `AppEnvironment.swift`).

## I 20 scenari richiesti

Legenda: ✅ eseguito in CI con esito positivo · 🟡 coperto solo in parte (cosa manca è scritto) · ⛔ non eseguibile qui: richiede hardware reale e **non è stato eseguito**.

| # | Scenario | Test | Esito |
|---|---|---|---|
| 1 | Installazione di un addon valido | `AddonFlowUITests.testInstallValidAddonByTypingItsURL`, `testInstallThroughDeepLink`; core: `AddonRegistryTests` | RISULTATI_1 |
| 2 | Rifiuto di un manifest non valido | `AddonFlowUITests.testRejectsInvalidManifests`, `testRejectsNonHTTPSchemes`; core: `ModelTests`, `NetworkTests`, `AddonRegistryTests` | RISULTATI_2 |
| 3 | Caricamento di cataloghi | `BrowseUITests.testCatalogsLoadOnHomeAndDiscover`; core: `ServiceTests` (catalogo, paginazione, cache) | RISULTATI_3 |
| 4 | Ricerca | `BrowseUITests.testSearchFindsTitlesAndShowsEmptyState`; core: `ServiceTests` (ricerca concorrente, debounce lato UI, dedupe) | RISULTATI_4 |
| 5 | Apertura dei dettagli | `BrowseUITests.testDetailsShowMetadata`, `testSeriesShowsEpisodes` | RISULTATI_5 |
| 6 | Più sorgenti | `BrowseUITests.testSourcesFromTheAddonAreListed`; core: `ServiceTests`, `PlaybackTests` (ordinamento) | RISULTATI_6 |
| 7 | Avvio della riproduzione | `PlaybackUITests.testPlaybackStartsAndTimeAdvances`, `testPauseStopsTheClock` | RISULTATI_7 |
| 8 | Ripresa dal punto salvato | `PlaybackUITests.testResumeFromSavedPosition`; core: `LibraryTests` | RISULTATI_8 |
| 9 | Selezione dei sottotitoli | `PlaybackUITests.testSelectingASubtitleShowsItsText`; core: parser SRT/VTT/ASS in `PlaybackTests` | RISULTATI_9 |
| 10 | Episodio successivo | `PlaybackUITests.testNextEpisodeStartsAutomatically`; core: `NextEpisodeResolver` in `PlaybackTests` | RISULTATI_10 |
| 11 | Watchlist | `PlaybackUITests.testWatchlistAddsAndRemoves`; core: `LibraryTests` | RISULTATI_11 |
| 12 | Ripristino della cronologia | `PlaybackUITests.testHistoryIsRestoredAfterRelaunch`; app: `BackupServiceTests`; core: `BackupMerge` in `LibraryTests` | RISULTATI_12 |
| 13 | Addon offline | `AddonFlowUITests.testInstallingWhileAddonIsOfflineShowsAnError`, `testInstalledAddonGoingOfflineShowsRetryNotACrash`; `SettingsAndAccessibilityUITests.testCachedCatalogsSurviveAnOfflineAddon` | RISULTATI_13 |
| 14 | Sorgente non supportata | `BrowseUITests.testUnsupportedSourcesAreFlaggedInsteadOfPlayed`; core: `StreamAnalyzer`/`PlaybackErrorMapper` in `PlaybackTests` | RISULTATI_14 |
| 15 | Connessione/disconnessione AirPlay | `testPlayerExposesCastAndAirPlayControls` verifica solo che il selettore di sistema sia raggiungibile. La connessione a un ricevitore AirPlay reale **non è stata provata** | ⛔ (hardware) |
| 16 | Google Cast su dispositivo reale | Nessun test su un Chromecast/Android TV reale. Compilazione con l'SDK ufficiale verificata in CI; logica di sessione provata con ricevitori finti (`CastCoordinatorTests`) | ⛔ (hardware) |
| 17 | Errori di rete durante il casting | `CastCoordinatorTests` (connessione fallita, ricevitore che rifiuta, perdita di connessione, fine sessione, cambio protocollo); core: `UPnPTests` (fault SOAP, HTTP). Con un televisore reale: **non provato** | RISULTATI_17 |
| 18 | Persistenza delle impostazioni | `SettingsAndAccessibilityUITests.testSettingsPersistAcrossRelaunch`; app: `SettingsStoreTests`; core: `MiscTests` (decodifica tollerante) | RISULTATI_18 |
| 19 | Cache e memoria | `ImageLoaderTests` (coalescing, disco, ridimensionamento, limite), core: `MiscTests`/`ServiceTests` (ResponseCache, stale-on-error) | RISULTATI_19 |
| 20 | VoiceOver e accessibilità | `testMainScreensPassTheAccessibilityAudit` (audit automatico di Apple su Home, Altro, Cerca), `testPlayerControlsHaveAccessibilityLabels`. **La navigazione con VoiceOver su un dispositivo non è stata eseguita** | RISULTATI_20 |

## Cosa i test non possono dire

* Nessuna prova su iPhone fisico: prestazioni reali, PiP, riproduzione in background con schermo bloccato, interruzioni telefoniche, Cast/AirPlay/DLNA verso televisori reali, Local Network prompt.
* L'SDK di iOS 27 non era disponibile: i test girano su iOS 26.5 (SDK e simulatore del runner).
* I test UI usano un video sintetico H.264/MP4: non verificano HEVC, HDR, Dolby, HLS multi-bitrate né sottotitoli incorporati.
* La resa dei sottotitoli è verificata come testo presente sullo schermo, non come aspetto grafico.

## Esiti dell'ultima esecuzione

RISULTATI_RUN
