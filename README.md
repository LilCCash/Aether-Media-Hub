# Aether — media center per iPhone

Aether è un media center nativo (Swift / SwiftUI) per iPhone che parla il **protocollo degli addon Stremio**.
È un progetto indipendente: codice, nome, interfaccia e icona sono originali (vedi [`NOTICE`](NOTICE) e [`docs/03-LICENSES.md`](docs/03-LICENSES.md)).
Non fornisce contenuti: mostra e riproduce ciò che gli addon installati dall'utente restituiscono.

> **Stato in una riga:** il codice compila e i test automatici girano su macOS in CI; **non è stato provato su un iPhone fisico**, non esiste un IPA firmato (il workflow *Build IPA* compone un IPA **non firmato**, da firmare con il tuo Apple ID), e alcune funzioni (AirPlay, Google Cast, DLNA, VoiceOver, Picture in Picture) sono implementate ma **non verificate con hardware reale**. Il dettaglio è in [Stato reale](#stato-reale).

## Documentazione

| Documento | Contenuto |
|---|---|
| [`docs/01-RESEARCH-MATRIX.md`](docs/01-RESEARCH-MATRIX.md) | Fase 1: ricerca su Stremio/Nuvio, matrice delle funzioni, licenze, limiti iOS |
| [`docs/02-ARCHITECTURE.md`](docs/02-ARCHITECTURE.md) | Architettura, moduli, sicurezza |
| [`docs/03-LICENSES.md`](docs/03-LICENSES.md) | Licenza e obblighi di ogni dipendenza |
| [`docs/04-TESTING.md`](docs/04-TESTING.md) | Scenari di test, fixture, cosa è stato davvero eseguito |

## Struttura

```
Packages/AetherCore   Libreria Swift solo-Foundation: protocollo addon, rete sicura, ricerca, libreria,
                      backup, analisi stream, sottotitoli, UPnP, download, impostazioni (testata con `swift test`)
App/Aether            App SwiftUI (MVVM): Home, Scopri, Cerca, Libreria, Download, Addon, Player, Casting, Impostazioni
App/AetherTests       Test unitari dell'app (impostazioni, router, Portachiavi…)
App/AetherUITests     Test UI contro un server di addon di prova (Tools/FixtureAddonServer)
Tools/                Server addon di prova per i test UI
Config/               xcconfig (firma, bundle id, versione)
project.yml           Definizione del progetto per XcodeGen (il `.xcodeproj` non è versionato)
```

## Compilare

Requisiti: macOS con Xcode 26 o successivo, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open Aether.xcodeproj
```

Poi scegli lo schema **Aether** e un iPhone (simulatore o dispositivo). Dalla riga di comando, per il simulatore:

```bash
xcodebuild test -project Aether.xcodeproj -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AetherTests CODE_SIGNING_ALLOWED=NO
```

Solo il nucleo (testato su macOS in CI; non l'ho provato su Linux):

```bash
cd Packages/AetherCore && swift test
```

### Firma e installazione su iPhone

Aether **non contiene** credenziali. Per installarlo sul tuo iPhone serve un account Apple Developer (anche gratuito per l'installazione personale):

1. Crea `Config/Signing.local.xcconfig` (ignorato da git):
   ```
   DEVELOPMENT_TEAM = TUOTEAMID
   APP_BUNDLE_ID = com.tuonome.aether
   ```
2. `xcodegen generate`, apri il progetto, collega l'iPhone, scegli **Run**. Xcode gestisce certificato e profilo con la firma automatica.
3. Alla prima apertura iOS chiede il permesso «Rete locale» (serve a Google Cast, DLNA e agli addon nella tua LAN).

### Comporre l'IPA su GitHub

> **Costo dei minuti:** su un repository **privato** i minuti dei runner macOS contano 10×. Ogni esecuzione completa della CI (con i test UI, ~15 minuti) ne consuma molti, e dopo una lunga serie di prove i job hanno smesso di partire (falliscono in pochi secondi senza eseguire alcun passo: la causa più probabile è la quota esaurita; controlla *Settings ▸ Billing* del tuo account). Per questo i test UI ora girano solo su `main` e sulle esecuzioni manuali; gli altri push compilano e lanciano i test unitari (~4 minuti), e le modifiche alla sola documentazione non avviano la CI. Un repository pubblico non ha questo limite.

Il workflow **Build IPA** (`.github/workflows/build-ipa.yml`) compone il file `.ipa` sui runner macOS di GitHub. Si avvia da *Actions ▸ Build IPA ▸ Run workflow*, quando spingi un tag `v*` e quando il file del workflow cambia.

| Modalità | Credenziali | Risultato | Stato |
|---|---|---|---|
| **Non firmato** (predefinita) | nessuna | artefatto `Aether-unsigned-ipa` con `Aether-unsigned.ipa` (arm64, Release, ~7,7 MB compresso); con un tag `v*` un job separato lo allega a una *release* di GitHub | ✅ la prima versione è stata eseguita in CI: archivio Release per iPhone e pacchetto verificato (bundle id, deployment target, binario solo arm64 per dispositivo, Google Cast SDK incorporato, asset, privacy manifest, schemi URL, nessuna firma). 🟡 Le correzioni successive (versione e build number letti da `project.yml`/xcconfig, job di release separato, controlli più severi) **non sono ancora state eseguite**: i runner macOS non si sono avviati (probabile quota esaurita, vedi sotto) |
| **Firmato** (spunta *sign* nell'esecuzione manuale) | i tuoi secret (sotto) | `Aether-signed-ipa`, installabile sui dispositivi del tuo profilo | 🟡 scritto ma **mai eseguito**: richiede il tuo certificato e il tuo profilo |

L'IPA non firmato **non si installa così com'è**: iOS richiede una firma. Va firmato di nuovo con il tuo Apple ID (per esempio con AltStore o Sideloadly) o con un tuo certificato. Non ho potuto provare l'installazione su un iPhone reale.

Per la modalità firmata crea questi *repository secret* (Settings ▸ Secrets and variables ▸ Actions): `APPLE_TEAM_ID`, `APP_BUNDLE_ID` (l'identificativo registrato nel tuo profilo), `BUILD_CERTIFICATE_BASE64` (il `.p12` in base64), `P12_PASSWORD` (la password che hai scelto esportando il `.p12`), `PROVISIONING_PROFILE_BASE64` (il `.mobileprovision` in base64). Il workflow non chiede mai password Apple, si ferma con un errore chiaro se manca un secret, verifica la firma e il profilo incorporato prima di caricare il file e rimuove certificato e keychain al termine.

Alternativa locale, anch'essa non verificata perché richiede le tue credenziali: `Scripts/archive.sh` (usa `Config/Signing.local.xcconfig` e `Config/ExportOptions.plist`, derivato da `Config/ExportOptions.plist.example`).

### iOS 27 e SDK

L'obiettivo di progetto è iOS 27 con iPhone 18 Pro Max, ma **l'SDK di iOS 27 non era disponibile** nell'ambiente di sviluppo/CI (Xcode 26.x, SDK iOS 26.5). L'app è compilata con quell'SDK, ha deployment target iOS 17 e usa le API *Liquid Glass* (`glassEffect`, `GlassEffectContainer`) solo con `#available(iOS 26, *)` e un fallback a materiali. Nessuna API di iOS 27 è usata: quando l'SDK sarà disponibile, ricompilare e verificare.

## Stato reale

Legenda: ✅ implementato e coperto da test automatici eseguiti in CI · 🟡 implementato, **non verificato** su hardware/sistema reale · ❌ non implementato (dichiarato).

### Addon e catalogo
| Funzione | Stato |
|---|---|
| Installazione da URL, `stremio://`, `aether://`, pagina `/configure`; manifest validato; duplicati rilevati | ✅ |
| Abilita/disabilita/riordina/aggiorna/rimuovi addon; salute dell'addon; avviso per addon sconosciuti | ✅ (logica) · 🟡 (UI) |
| Risorse `catalog`, `meta`, `stream`, `subtitles`, `addon_catalog`; extra (search, genre, skip); paginazione; cache con `cacheMaxAge`/stale; richieste concorrenti con timeout e cancellazione | ✅ |
| Decodifica tollerante (campi mancanti, numeri come stringhe, elementi malformati scartati) | ✅ |
| Ricerca remota su più addon con debounce, deduplicazione per IMDb/titolo+anno, ordinamenti; ricerca locale | ✅ |
| Plugin / scraper di Nuvio, esecuzione di codice scaricato | ❌ (volutamente: sicurezza) |

### Riproduzione
| Funzione | Stato |
|---|---|
| Analisi delle sorgenti (qualità, codec, HDR, audio, lingue, dimensione) e ordinamento; sorgenti non riproducibili segnalate prima della riproduzione | ✅ |
| AVPlayer: MP4/MOV/M4V/HLS, ripresa, salto avanti/indietro, velocità, gesti, blocco controlli, timer di spegnimento, riempi schermo | 🟡 |
| Sottotitoli esterni SRT/VTT/ASS con rilevamento codifica, ritardo regolabile, stile persistente, importazione da file; tracce audio e sottotitoli incorporati | ✅ (parser) · 🟡 (resa nel player) |
| Episodio successivo con prefetch delle sorgenti, conto alla rovescia, riproduzione automatica, continuità del gruppo di rilascio | ✅ (logica) · 🟡 (player) |
| Picture in Picture, audio in background, schermata di blocco (Now Playing), interruzioni (telefonate), ripresa dopo perdita di rete | 🟡 |
| MKV, AVI, WebM, DASH, torrent integrato, YouTube nel player, motore MPV/VLC | ❌ (le sorgenti sono segnalate come non riproducibili; l'architettura prevede `PlaybackEngine`) |

### Casting
| Funzione | Stato |
|---|---|
| AirPlay (selettore di sistema, riproduzione esterna di AVPlayer) | 🟡 |
| Google Cast (SDK ufficiale, Default Media Receiver, scoperta, invio, controlli) | 🟡 |
| DLNA/UPnP: SOAP AVTransport, DIDL-Lite, parsing delle descrizioni | ✅ (protocollo, con fixture) · 🟡 (televisori reali) |
| DLNA: scoperta SSDP | 🟡 richiede l'entitlement multicast di Apple; senza di esso resta l'aggiunta manuale dell'indirizzo |
| Controllo preventivo di compatibilità (URL locali, header, contenitore, codec) | ✅ |
| Sottotitoli esterni di Aether sul televisore | ❌ (solo tracce incorporate) |

Android TV è trattato come caso distinto: compare in Google Cast solo con «Chromecast integrato»; altrimenti serve un ricevitore DLNA sul televisore e l'indirizzo va inserito a mano.

### Libreria, download, dati
| Funzione | Stato |
|---|---|
| Continua a guardare, prossimi episodi, watchlist, preferiti, cronologia, ricerche recenti; interruttore privacy che non registra nulla | ✅ |
| Backup e ripristino JSON con unione (ultimo modificato + tombstone), con o senza URL degli addon | ✅ |
| Download di file diretti in background, pausa/ripresa, spazio, solo Wi-Fi, riproduzione offline, eliminazione dopo la visione | ✅ (pianificazione) · 🟡 (sessione in background su dispositivo) |
| Download di HLS, torrent, DRM | ❌ (rifiutati con spiegazione) |
| Account Stremio/Nuvio e sincronizzazione cloud, Trakt, Simkl | ❌ (nessuna API pubblica documentata per client di terze parti: vedi `docs/01-RESEARCH-MATRIX.md` §5) |
| Widget, notifiche di nuovi episodi | ❌ |

### Interfaccia
Home (hero, continua, prossimi, watchlist, cataloghi), Scopri (tipo/catalogo/genere), Cerca, Libreria, Download, Addon, Impostazioni; skeleton di caricamento, nessuna sezione vuota, tema chiaro/scuro/automatico, accento, dimensione locandine. Liquid Glass applicato a barre e controlli flottanti, con alternativa a materiale quando l'utente attiva «Riduci effetti» o «Riduci trasparenza». Etichette e azioni di accessibilità sono presenti, ma **VoiceOver non è stato provato su un dispositivo**.

### Sicurezza e privacy
Solo `http`/`https`; niente credenziali negli URL; blocco di loopback/reti private/link-local/CGNAT/multicast (anche IPv4 mappato su IPv6, numeri decimali/esadecimali e rebinding DNS) salvo opt-in «rete locale»; redirect rivalidati (max 5, mai https→http); limiti di dimensione (manifest 1 MiB, risposte 8 MiB, sottotitoli 4 MiB); URL degli addon (che possono contenere chiavi) nel Portachiavi; log con redazione; nessun analytics e nessun invio di dati a server di Aether; nessun codice eseguito dagli addon.

## Test

Ultima esecuzione completa in CI (macOS, Xcode 26.6, simulatore iPhone, iOS SDK 26.5) sul commit unito in `main`:

| Suite | Test | Falliti |
|---|---|---|
| AetherCore (`swift test`) | 172 | 0 |
| Unit dell'app | 42 | 0 |
| UI contro addon di fixture (riproduzione reale di un MP4 H.264 nel simulatore) | 30 | 0 |

[`docs/04-TESTING.md`](docs/04-TESTING.md) mappa ciascuno dei 20 scenari richiesti sul test che lo verifica e dice quali **non** sono stati eseguiti su hardware reale (AirPlay, Google Cast su Chromecast/Android TV, VoiceOver su dispositivo, DLNA su televisori, rete mobile).

## Contribuire / licenza

MIT (`LICENSE`). Le dipendenze e i riferimenti studiati sono elencati in `docs/03-LICENSES.md`.
