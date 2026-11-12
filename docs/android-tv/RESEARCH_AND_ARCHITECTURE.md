# Aether Android TV — ricerca e architettura

## Branch e base
- Branch `aether-android-tv-new`, nato da un commit radice vuoto (orfano): nessun file dell'app iOS né del vecchio progetto Android,
  storia pulita. I riferimenti (`aether-swift-features`, `feature/aether-android-tv-addon-cancellation-fix`) restano intatti.

## Versioni (verificate sui repository Maven l'11/11/2026)
AGP 9.5.1 (Kotlin incorporato, niente plugin `kotlin-android`) · Gradle 9.9.1 · Kotlin 2.4.21 (Compose compiler plugin uguale) ·
compileSdk/targetSdk 37 · minSdk 24 · JDK 21 per la build, bytecode Java 17 · Compose BOM 2026.09.00 (foundation + material3) ·
Media3 1.11.1 · Navigation Compose 2.10.2 · Lifecycle 2.11 · Activity Compose 1.13 · WorkManager 2.12 · ProfileInstaller 1.4.1 ·
OkHttp 5.5.1 · kotlinx.serialization 1.13 · coroutines 1.11 · Coil 3.6.3 · ZXing core 3.5.4 · NanoHTTPD 2.3.1.

Prima ero partito da AGP 8.13 / SDK 36: le librerie attuali (Activity 1.13, Lifecycle 2.11, Media3 1.11) richiedono compileSdk 37,
che a sua volta richiede AGP ≥ 9.1, e AGP 9.5 richiede Gradle ≥ 9.6. Il progetto è quindi sull'ultima toolchain stabile.

## Scelte e motivi
| Area | Scelta | Perché |
|---|---|---|
| UI | Jetpack Compose (foundation + material3) con superfici di focus proprie (`FocusSurface`) | Leanback è in manutenzione; `tv-material` è stato provato e tolto: le superfici proprie (bordo, scala e colore di focus, pressione lunga) bastano, pesano meno e restano uguali su tutte le versioni. Rendering pigro con `LazyRow`/`LazyColumn` + chiavi stabili. |
| Moduli | `core` (Kotlin puro, JVM) + `app` (Android) | Il minimo per separare logica (testabile in secondi su JVM) e piattaforma. Più moduli non darebbero vantaggi misurabili qui. |
| Rete | OkHttp 5 condiviso, timeout, cache su disco, coroutines con annullamento | Un solo pool di connessioni; l'annullamento della coroutine annulla la `Call`. |
| JSON | kotlinx.serialization, parsing tollerante | Nessuna riflessione (più leggero di Moshi/Gson riflessivi), adatto a R8. |
| Persistenza | file JSON atomici (come iOS `JSONFileStore`) | Stesso formato del backup iOS → ripristino tra piattaforme; nessun ORM per pochi KB di dati. |
| Chiavi | Android Keystore AES-GCM | Niente dipendenze (security-crypto è deprecata); chiavi mai nei log. |
| Immagini | Coil 3 con dimensioni richieste per card, cache memoria limitata, cache disco | Decodifica alla misura giusta, niente full-resolution per le card. |
| Player | Media3 ExoPlayer (MKV, MP4, HLS, DASH; HEVC/AV1/HDR via MediaCodec) | Decodifica hardware, sottotitoli SRT/SSA/VTT/PGS, selezione tracce. Capacità rilevate con `MediaCodecList` e `Display.HdrCapabilities`. |
| Download | WorkManager con lavoro in primo piano, OkHttp a intervalli (Range) | Sopravvive alla chiusura del processo; ripresa dall'ultimo byte. |
| Configurazione da telefono | server LAN temporaneo (NanoHTTPD), sessione breve, token nel QR, conferma sulla TV | Evolve la soluzione già funzionante del branch di riferimento (vedi sotto). |
| DI | costruzione manuale (un `AetherEngine` pigro) | Hilt/Koin non danno vantaggi misurabili per due moduli e aumentano avvio e APK. |
| Avvio | inizializzazione pigra, Baseline Profile (ProfileInstaller) | Avvio a freddo più veloce sui box lenti. |
| ABI | nessuna libreria nativa propria → APK unico | Nessuna variante per ABI da produrre. |

## Lezioni dal vecchio Android TV
- Buono e riusato come idea: separazione `core`/`app`, `AddonRemoteServer` (token casuale, confronto a tempo costante, server
  attivo solo con la schermata aperta), `TorBox` e `MetadataEnrichment` nel core, test JVM rapidi.
- Da migliorare: aggiornamenti di salute degli addon che rilanciavano i cataloghi (corretto nel branch), server QR sempre sulla
  porta 8765 su tutte le interfacce senza scadenza né conferma, chiavi limitate a TMDB/TVDB/TorBox, nessun Real-Debrid/Trakt.

## Fonti principali
- Android TV e Compose for TV: developer.android.com/training/tv, developer.android.com/jetpack/androidx/releases/tv
- Media3: developer.android.com/media/media3/exoplayer (formati supportati, selezione tracce, sottotitoli)
- Prestazioni: developer.android.com/topic/performance/baselineprofiles, developer.android.com/jetpack/compose/performance
- Protocollo addon Stremio: github.com/Stremio/stremio-addon-sdk/tree/master/docs/api
- Real-Debrid API: api.real-debrid.com (device code OAuth) · TorBox API: api-docs.torbox.app
- GitHub Actions/Gradle: github.com/gradle/actions (setup-gradle con cache), docs.gradle.org (configuration cache)


## Moduli realizzati
- `core` (Kotlin puro): addon (registro, client, pianificazione, instradamento debrid), modelli, rete (OkHttp, regole di rete), metadati
  (TMDB, TheTVDB, fanart, MDBList), libreria e backup compatibili iOS, ricerca, riproduzione (analisi, punteggio, selezione,
  sottotitoli, IntroDB), debrid (TorBox, Real-Debrid, `DebridRouter`), TV in diretta (M3U, XMLTV, abbinamento canali), Trakt,
  download (`DownloadStore`), sessione di configurazione da telefono (`PhoneLinkSession`), impostazioni.
- `app` (Android): navigazione e schermate Compose, player Media3, `PhoneConfigServer` (NanoHTTPD), `DownloadWorker` (WorkManager),
  `DeviceCapabilities`, `AndroidSecretStore` (Keystore AES-GCM).

## Sicurezza
- Nessuna chiave nel codice: TMDB, TheTVDB, fanart, MDBList, TorBox e Real-Debrid li inserisce l'utente (cifrati con Keystore).
  L'unico identificativo incluso è il Client ID pubblico di Trakt (non è un segreto, viaggia in ogni richiesta; sostituibile con
  `-PaetherTraktClientId`). La vecchia chiave di progetto fanart.tv del riferimento è stata tolta.
- Gli indirizzi di download (che possono contenere token) sono nel deposito cifrato e cancellati a download finito.
- Configurazione da telefono: vedi `PhoneConfigServer` e il punto 43 della tabella di parità. Limite: HTTP in chiaro dentro la rete
  di casa (un browser non può usare WebCrypto su HTTP locale e un certificato autofirmato darebbe un avviso); la pagina lo dice.

## Design (rifatto da zero)
Stile tvOS / app TV di Apple: nero neutro, superfici di «vetro» bianco trasparente, testo bianco, barra delle sezioni in alto
(Cerca e Impostazioni come icone tonde), titoli in evidenza a tutto schermo con il logo del titolo, scheda titolo con lo sfondo a
tutta pagina, impostazioni a due colonne, barra del player bassa e pulita. L'elemento sotto il telecomando si «solleva»: più grande,
con un bordo chiaro e un'ombra morbida; pulsanti, pillole e righe delle impostazioni diventano bianchi con testo scuro.
Schermate di prova (generate da `ScreenshotGallery`, Robolectric con grafica nativa: `./gradlew :app:testDebugUnitTest
--tests '*ScreenshotGallery' -PaetherScreenshots=true`): `docs/android-tv/screenshots/`.
