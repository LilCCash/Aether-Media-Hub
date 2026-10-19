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
| 1 | Installazione di un addon valido | `AddonFlowUITests.testInstallValidAddonByTypingItsURL`, `testInstallThroughDeepLink`; core: `AddonRegistryTests` | ✅ |
| 2 | Rifiuto di un manifest non valido | `AddonFlowUITests.testRejectsInvalidManifests`, `testRejectsNonHTTPSchemes`; core: `ModelTests`, `NetworkTests`, `AddonRegistryTests` | ✅ |
| 3 | Caricamento di cataloghi | `BrowseUITests.testCatalogsLoadOnHomeAndDiscover`; core: `ServiceTests` (catalogo, paginazione, cache) | ✅ |
| 4 | Ricerca | `BrowseUITests.testSearchFindsTitlesAndShowsEmptyState`; core: `ServiceTests` (ricerca concorrente, debounce lato UI, dedupe) | ✅ |
| 5 | Apertura dei dettagli | `BrowseUITests.testDetailsShowMetadata`, `testSeriesShowsEpisodes` | ✅ |
| 6 | Più sorgenti | `BrowseUITests.testSourcesFromTheAddonAreListed`; core: `ServiceTests`, `PlaybackTests` (ordinamento) | ✅ |
| 7 | Avvio della riproduzione | `PlaybackUITests.testPlaybackStartsAndTimeAdvances`, `testPauseStopsTheClock` | ✅ |
| 8 | Ripresa dal punto salvato | `PlaybackUITests.testResumeFromSavedPosition`; core: `LibraryTests` | ✅ |
| 9 | Selezione dei sottotitoli | `PlaybackUITests.testSelectingASubtitleShowsItsText`; core: parser SRT/VTT/ASS in `PlaybackTests` | ✅ |
| 10 | Episodio successivo | `PlaybackUITests.testNextEpisodeStartsAutomatically`; core: `NextEpisodeResolver` in `PlaybackTests` | ✅ |
| 11 | Watchlist | `PlaybackUITests.testWatchlistAddsAndRemoves`; core: `LibraryTests` | ✅ |
| 12 | Ripristino della cronologia | `PlaybackUITests.testHistoryIsRestoredAfterRelaunch`; app: `BackupServiceTests`; core: `BackupMerge` in `LibraryTests` | ✅ |
| 13 | Addon offline | `AddonFlowUITests.testInstallingWhileAddonIsOfflineShowsAnError`, `testInstalledAddonGoingOfflineShowsRetryNotACrash`; `SettingsAndAccessibilityUITests.testCachedCatalogsSurviveAnOfflineAddon` | ✅ |
| 14 | Sorgente non supportata | `BrowseUITests.testUnsupportedSourcesAreFlaggedInsteadOfPlayed`; core: `StreamAnalyzer`/`PlaybackErrorMapper` in `PlaybackTests` | ✅ |
| 15 | Connessione/disconnessione AirPlay | `testPlayerExposesCastAndAirPlayControls` verifica solo che il selettore di sistema sia raggiungibile. La connessione a un ricevitore AirPlay reale **non è stata provata** | ⛔ (hardware) |
| 16 | Google Cast su dispositivo reale | Nessun test su un Chromecast/Android TV reale. Compilazione con l'SDK ufficiale verificata in CI; logica di sessione provata con ricevitori finti (`CastCoordinatorTests`) | ⛔ (hardware) |
| 17 | Errori di rete durante il casting | `CastCoordinatorTests` (connessione fallita, ricevitore che rifiuta, perdita di connessione, fine sessione, cambio protocollo); core: `UPnPTests` (fault SOAP, HTTP). Con un televisore reale: **non provato** | 🟡 solo con ricevitori simulati; nessun televisore reale |
| 18 | Persistenza delle impostazioni | `SettingsAndAccessibilityUITests.testSettingsPersistAcrossRelaunch`; app: `SettingsStoreTests`; core: `MiscTests` (decodifica tollerante) | ✅ |
| 19 | Cache e memoria | `ImageLoaderTests` (coalescing, disco, ridimensionamento, limite), core: `MiscTests`/`ServiceTests` (ResponseCache, stale-on-error) | ✅ |
| 20 | VoiceOver e accessibilità | `testMainScreensPassTheAccessibilityAudit` (audit automatico di Apple su Home, Altro, Cerca), `testPlayerControlsHaveAccessibilityLabels`. **La navigazione con VoiceOver su un dispositivo non è stata eseguita** | 🟡 audit automatico superato per descrizioni, aree di tocco e trait; restano note sul contrasto (sotto); VoiceOver su dispositivo non eseguito |

## Cosa i test non possono dire

* Nessuna prova su iPhone fisico: prestazioni reali, PiP, riproduzione in background con schermo bloccato, interruzioni telefoniche, Cast/AirPlay/DLNA verso televisori reali, Local Network prompt.
* L'SDK di iOS 27 non era disponibile: i test girano su iOS 26.5 (SDK e simulatore del runner).
* I test UI usano un video sintetico H.264/MP4: non verificano HEVC, HDR, Dolby, HLS multi-bitrate né sottotitoli incorporati.
* La resa dei sottotitoli è verificata come testo presente sullo schermo, non come aspetto grafico.

## Esiti dell'ultima esecuzione

Ultima esecuzione completa (GitHub Actions, `macos-latest`, Xcode 26.6, SDK iOS 26.5, simulatore iPhone più recente della serie Pro Max disponibile sul runner):

| Suite | Test eseguiti | Falliti |
|---|---|---|
| AetherCore (`swift test`) | 172 | 0 |
| Unit dell'app (`AetherTests`) | 42 | 0 |
| UI (`AetherUITests`, ~13 minuti) | 30 | 0 |

Ogni esecuzione completa è nel registro di GitHub Actions (job «App (build, unit tests, UI tests)» e «AetherCore (swift test)»); i bundle `.xcresult` con screenshot e allegati sono salvati come artefatto per 7 giorni.

### Problemi trovati dai test e corretti

* **Perdita della cronologia.** Il test «cronologia dopo il riavvio» ha mostrato che, chiudendo il player e terminando l'app subito dopo, l'ultimo punto di ripresa non arrivava su disco: la scrittura è ritardata (debounce) e il `flush` poteva partire prima della registrazione. Ora la chiusura del player registra e scrive in un passo ordinato e l'app scrive anche quando la scena smette di essere attiva (con un background task).
* **Test che passavano a vuoto.** Le prime versioni dei test di ripresa e cronologia riproducevano meno di 10 s, sotto la soglia con cui l'app decide di registrare: il test di ripresa passava anche senza ripresa. Ora superano la soglia e la ripresa è verificata in modo che solo un vero salto al punto salvato possa soddisfarla.
* **Tipografia fissa.** L'audit di Apple ha segnalato titoli che non seguivano Dynamic Type; ora usano gli stili di testo di sistema. Il contrasto del testo secondario è stato aumentato.

### Note ancora aperte (audit di accessibilità, informativo)

`testAuditReportForContrastAndDynamicType` non fa fallire la build: elenca nel log le voci `A11Y-ISSUE`. Dopo le correzioni restano segnalazioni di contrasto su didascalie (anni) e su titoli delle locandine dei cataloghi di fixture e sul banner in evidenza. Non ho confermato la causa (possibile sovrapposizione con la barra delle schede traslucida di iOS 26 o con le locandine sintetiche); va riesaminata su dispositivo con copertine reali e VoiceOver.
