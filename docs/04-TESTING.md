# Test: strategia, scenari e risultati reali

Questo documento dice **cosa è stato eseguito davvero** e cosa no. Nessun test hardware è dichiarato superato se non è stato eseguito su hardware reale.

## Livelli

> Costo: su un repository privato i minuti macOS di GitHub valgono 10×. I test UI (~15 min) girano solo su `main` e con *Run workflow*; gli altri push eseguono build e test unitari. L'ultima esecuzione completa dei test UI è quella riportata in fondo.

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

## Verificato su un iPhone reale (riferito dall'utente, 2026-10-21)

Queste conferme non vengono da un test automatico né da una prova mia: le ha date il proprietario del progetto usando l'app su un iPhone, dopo la Beta 2.
- **Player:** il tasto play/pausa risponde al tocco (in Beta 1 il tocco si perdeva).
- **TorBox:** la riproduzione di un torrent in cache parte (in Beta 1 compariva «il link restituito contiene credenziali»). Verifica della cache, aggiunta e richiesta del link funzionano con un account reale.
- **Elenco sorgenti:** la pillola dello stato della cache ha l'aspetto atteso (compatta, con testo).
- **Cerca e Scopri:** i filtri per genere e per anno funzionano. Ne segue che i test UI dei filtri che in CI falliscono sono da riesaminare come difetti dei test e non dell'app (non ancora fatto).

Restano **non confermati su dispositivo**: «Salta intro / Salta riassunto» (Beta 3), le griglie di Scopri e Libreria (Beta 1), AirPlay, Google Cast, DLNA, Picture in Picture, HDR / Dolby Vision, VoiceOver.

## 1.1 Beta 1: cosa è stato eseguito (CI, simulatore, 2026-10-21)

| Suite | Test | Esito |
|---|---|---|
| AetherCore (`swift test`) | 610 | tutti passati (nuovi: `BackgroundPolicyTests`, `AppearanceCustomizationTests`) |
| Unit dell'app | 274 | tutti passati (nuovi: `AppearanceStyleTests`, `LogoEasterEggTests`) |
| UI `HomeCustomizationUITests` | 17 | tutti passati |
| UI `LayoutUITests`, `BrowseUITests`, `SettingsAndAccessibilityUITests` | 22 | tutti passati |

Un controllo indipendente del codice (sei revisori) ha trovato difetti prima della release; sono stati corretti e coperti da test. Il controllo automatico di accessibilità segnala ancora **note sul contrasto** del testo secondario sul catalogo di prova (già presenti in 1.0).

**Non verificato:** l'aspetto reale di atmosfere, sfondi, cornici e schermo intero; il Picture in Picture (anche in contenitori come LiveContainer); l'easter egg con aptica e VoiceOver su un dispositivo; il tasto Cast con dispositivi veri.

## Cosa i test non possono dire

* Nessuna prova su iPhone fisico: prestazioni reali, PiP, riproduzione in background con schermo bloccato, interruzioni telefoniche, Cast/AirPlay/DLNA verso televisori reali, Local Network prompt.
* L'SDK di iOS 27 non era disponibile: i test girano su iOS 26.5 (SDK e simulatore del runner).
* I test UI usano un video sintetico H.264/MP4: non verificano HEVC, HDR, Dolby, HLS multi-bitrate né sottotitoli incorporati.
* La resa dei sottotitoli è verificata come testo presente sullo schermo, non come aspetto grafico.

## Esiti dell'ultima esecuzione

Commit `57a5a04` (GitHub Actions, `macos-latest`, Xcode 26.6, SDK iOS 26.5, simulatore iPhone). I test UI sono stati lanciati tutti insieme e il job è stato fermato dal limite di 90 minuti: i risultati sotto sono quelli delle classi arrivate in fondo; le classi `SettingsAndAccessibilityUITests` e quasi tutta `TorBoxUITests` **non sono state eseguite**. Da allora i test UI girano in gruppi paralleli (`ui_tests` accetta più bersagli separati da virgola).

| Suite | Test eseguiti | Esito |
|---|---|---|
| AetherCore (`swift test`) | 540 | 0 falliti |
| Unit dell'app (`AetherTests`) | 222 | 0 falliti |
| UI (`AetherUITests`), parziale | ~60 | vedi sotto |

**UI passati** (selezione significativa): installazione addon (6), esplorazione e dettagli (9, inclusi tipi dinamici e filtro per tipo), download e riproduzione offline (2), layout (dettaglio film, dettaglio serie, scelta sorgente, carosello Home, righe: 5), riproduzione (avvio, pausa, ripresa, cronologia, nessuna cronologia se disattivata, episodio successivo), sottotitoli (scelta lingua, chip, nessun addon, nessun sottotitolo, lingua preferita e secondaria, OpenSubtitles consigliato), matrice media: HEVC `hev1`.

**UI non passati e perché (nessuno risolto con certezza):**
* *Errori dei test, corretti dopo l'esecuzione e non riverificati:* le pagine di Impostazioni non erano raggiungibili dopo l'installazione di un addon (la pila di navigazione restava nell'elenco Addon) — 4 test Metadati, 1 TorBox, 3 di Scopri; l'elenco Informazioni sulla sorgente è una lista pigra e le righe sotto la piega non esistevano al momento della lettura; i fotogrammi dei biglietti della Home sono gonfiati dall'albero di accessibilità (escluso nel test di larghezza).
* *Da capire:* 7 test di Cerca/Scopri con un secondo addon («addon non elencato dopo l'installazione» — ora il messaggio riporta cosa c'è sullo schermo); `testWatchlistAddsAndRemoves` (timeout di interrogazione); 5 test dei sottotitoli (episodio successivo con lingua ricordata, file rotti, ritardo, hash calcolato sul dispositivo: **non confermato che il secondo giro con l'hash parta davvero**); matrice media: **AVI e HLG MP4 «il player non si apre»** (non so se difetto o instabilità del runner), e **nel foglio Informazioni il decoder mostra contenitore e motore ma nessuna riga «Video» / «Gamma dinamica»** (non confermato che i fatti HDR arrivino fino allo schermo nel simulatore).
* *Uscita video di MPV (Metal/MoltenVK) sul simulatore:* non confermata («Attiva» non osservato).

Ogni esecuzione è nel registro di GitHub Actions; i bundle `.xcresult` sono salvati come artefatto per 7 giorni. Una nuova esecuzione a gruppi sul commit `2906c8b` (che contiene le correzioni dei test) era in corso al momento della pubblicazione; se completa, l'esito è nel registro.

### Problemi trovati dai test e corretti

* **Perdita della cronologia.** Il test «cronologia dopo il riavvio» ha mostrato che, chiudendo il player e terminando l'app subito dopo, l'ultimo punto di ripresa non arrivava su disco: la scrittura è ritardata (debounce) e il `flush` poteva partire prima della registrazione. Ora la chiusura del player registra e scrive in un passo ordinato e l'app scrive anche quando la scena smette di essere attiva (con un background task).
* **Test che passavano a vuoto.** Le prime versioni dei test di ripresa e cronologia riproducevano meno di 10 s, sotto la soglia con cui l'app decide di registrare: il test di ripresa passava anche senza ripresa. Ora superano la soglia e la ripresa è verificata in modo che solo un vero salto al punto salvato possa soddisfarla.
* **Tipografia fissa.** L'audit di Apple ha segnalato titoli che non seguivano Dynamic Type; ora usano gli stili di testo di sistema. Il contrasto del testo secondario è stato aumentato.

### Note ancora aperte (audit di accessibilità, informativo)

`testAuditReportForContrastAndDynamicType` non fa fallire la build: elenca nel log le voci `A11Y-ISSUE`. Dopo le correzioni restano segnalazioni di contrasto su didascalie (anni) e su titoli delle locandine dei cataloghi di fixture e sul banner in evidenza. Non ho confermato la causa (possibile sovrapposizione con la barra delle schede traslucida di iOS 26 o con le locandine sintetiche); va riesaminata su dispositivo con copertine reali e VoiceOver.


## 1.2 Beta 1 — esiti

CI su `79358fd` (macOS, Xcode 26): **Core 881 test, app 349 test, 0 falliti**. Test UI lanciati a gruppi sul simulatore (commit `c13c066`–`3d288b9`):

| Gruppo | Esito |
|---|---|
| Impostazioni e accessibilità, layout, download, metadati | 22/22 |
| Esplora, filtri di Cerca | 14/14 |
| Salta intro | 3/3 |
| Home personalizzabile | 17/17 |
| Player (`PlaybackUITests`) | 18/20: `testSubtitleRequestsCarryTheFileNameAndTheHashComputedOnThisDevice` (noto da Alpha 2) e `testHistoryIsRestoredAfterRelaunch` (una volta su due; passa da solo) |
| TorBox | 10/12: `testAWrongKeyShowsTheInvalidKeyMessageAndIsNotKept`, `testANotCachedTorrentAsksBeforeDownloadingThenShowsProgressAndPlays` — **falliscono uguali sul codice di 1.1 Beta 1** (verificato con un'esecuzione sul tag) |
| Installazione addon | 6/6 isolati; `testInstallingWhileAddonIsOfflineShowsAnError` è fallito una volta in gruppo e passa da solo (anche su 1.1 Beta 1) |
| Matrice media (`PlayerMatrixUITests`) | 1/8: le righe «Video» / «Gamma dinamica» non compaiono nel foglio Informazioni nel simulatore e AVI / HLG MP4 non aprono il player (noti da Alpha 2) |

I tre test sulle chiavi TMDB / TheTVDB (`MetadataUITests`) fallivano già in 1.1 Beta 1 (l'etichetta letta era «Warning»); con lo stato della chiave esposto come un unico elemento di accessibilità ora passano.
Non è stato eseguito nulla su un iPhone né con un televisore.

## 1.3 Beta 1 — esiti (CI, simulatore)

- CI (Core + App con test unitari) verde sul commit `313b7b4`.
- UI `TheaterUITests` (entrata, sezioni della barra, uscita, pagina immersiva → dettagli): passati su `313b7b4`. Un primo tentativo falliva perché l'identificatore sul contenitore sostituiva quelli dei pulsanti interni; corretto.
- UI Home personalizzabile 17/17, Impostazioni/Accessibilità/Layout/Esplora e Cerca passati su `7caa40c`.
- Non verificato: aspetto e animazioni di Theater Mode su schermo, AirPlay con Apple TV. Fallimenti noti invariati (TorBox ×2, hash sottotitoli, matrice media).

## 1.3 rev2 — esiti (CI, simulatore)

- CI (Core + App con test unitari) verde su `9d21695`.
- UI `TheaterUITests` (barra senza Cerca, impostazioni con le voci di «Altro», Riproduci → scelta della sorgente di Theater) e Home personalizzabile: passati su `9d21695`; Impostazioni/accessibilità, layout, Esplora e Cerca: vedi il riepilogo della release.
- Non verificati: aspetto di Theater Mode su schermo, barra del volume con i tasti hardware, tocchi ripetuti, ritorno in orizzontale dopo il player, AirPlay con Apple TV.
