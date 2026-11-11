# Aether Android TV — ricerca e architettura

## Branch e base
- Branch `aether-android-tv-new`, nato da un commit radice vuoto (orfano): nessun file dell'app iOS né del vecchio progetto Android,
  storia pulita. I riferimenti (`aether-swift-features`, `feature/aether-android-tv-addon-cancellation-fix`) restano intatti.

## Versioni (verificate sui repository Maven il 11/11/2026)
AGP 8.13.2 · Kotlin 2.4.21 (Compose compiler plugin uguale) · Gradle 8.14 · compileSdk/targetSdk 36 · minSdk 24 ·
Compose BOM 2026.09.00 · androidx.tv:tv-material 1.1.0 · Media3 1.11.1 · Navigation Compose 2.10.2 · Lifecycle 2.11 ·
Activity Compose 1.13 · WorkManager 2.12 · ProfileInstaller 1.4.1 · OkHttp 5.5.1 · kotlinx.serialization 1.13 ·
coroutines 1.11 · Coil 3.6.3 · ZXing core 3.5.4 · NanoHTTPD 2.3.1.

AGP 9 è uscito ma cambia l'integrazione di Kotlin (Kotlin incorporato): resto sull'ultima 8.x, stabile e ben documentata, e
passo alla 9 quando serve.

## Scelte e motivi
| Area | Scelta | Perché |
|---|---|---|
| UI | Jetpack Compose + `androidx.tv:tv-material` | Raccomandata da Google per le nuove app TV (Leanback è in manutenzione); focus D-pad, `Surface`/`Card` con stato di focus, `ImmersiveList`. Rendering pigro con `LazyRow`/`LazyColumn` + chiavi stabili. |
| Moduli | `core` (Kotlin puro, JVM) + `app` (Android) | Il minimo per separare logica (testabile in secondi su JVM) e piattaforma. Più moduli non darebbero vantaggi misurabili qui. |
| Rete | OkHttp 5 condiviso, timeout, cache su disco, coroutines con annullamento | Un solo pool di connessioni; l'annullamento della coroutine annulla la `Call`. |
| JSON | kotlinx.serialization, parsing tollerante | Nessuna riflessione (più leggero di Moshi/Gson riflessivi), adatto a R8. |
| Persistenza | file JSON atomici (come iOS `JSONFileStore`) | Stesso formato del backup iOS → ripristino tra piattaforme; nessun ORM per pochi KB di dati. |
| Chiavi | Android Keystore AES-GCM | Niente dipendenze (security-crypto è deprecata); chiavi mai nei log. |
| Immagini | Coil 3 con dimensioni richieste per card, cache memoria limitata, cache disco | Decodifica alla misura giusta, niente full-resolution per le card. |
| Player | Media3 ExoPlayer (MKV, MP4, HLS, DASH; HEVC/AV1/HDR via MediaCodec) | Decodifica hardware, sottotitoli SRT/SSA/VTT/PGS, selezione tracce. Capacità rilevate con `MediaCodecList` e `Display.HdrCapabilities`. |
| Download | WorkManager con lavoro in primo piano, OkHttp a intervalli (Range) | Sopravvive alla chiusura del processo; ripresa dall'ultimo byte. |
| Configurazione da telefono | server LAN temporaneo (NanoHTTPD), sessione breve, token nel QR, conferma sulla TV | Evolve la soluzione già funzionante del branch di riferimento (vedi sotto). |
| DI | costruzione manuale (un `AppGraph` pigro) | Hilt/Koin non danno vantaggi misurabili per due moduli e aumentano avvio e APK. |
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
