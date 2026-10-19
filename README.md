# Aether — media center per iPhone

Aether è un media center nativo (Swift / SwiftUI) per iPhone che parla il **protocollo degli addon Stremio**.
È un progetto indipendente: codice, nome, interfaccia e icona sono originali (vedi [`NOTICE`](NOTICE) e [`docs/03-LICENSES.md`](docs/03-LICENSES.md)).
Non fornisce contenuti: mostra e riproduce ciò che gli addon installati dall'utente restituiscono.

> **Stato in una riga:** il codice compila e i test automatici girano su macOS in CI; **non è stato provato su un iPhone fisico**, non c'è un IPA firmato, e alcune funzioni (AirPlay, Google Cast, DLNA, VoiceOver, Picture in Picture) sono implementate ma **non verificate con hardware reale**. Il dettaglio è in [Stato reale](#stato-reale).

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

Solo il nucleo (anche su Linux):

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

**Non è fornito nessun IPA.** Un IPA installabile richiede un certificato e un profilo di provisioning del tuo account: non vengono mai chiesti password Apple e non è possibile produrlo in modo verificabile senza di essi. Per distribuire fuori dall'App Store servono un account a pagamento (Ad Hoc / Enterprise) o TestFlight; la riga `xcodebuild archive` + `-exportArchive` con il tuo `ExportOptions.plist` produce l'IPA firmato sulla tua macchina.

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

Vedi [`docs/04-TESTING.md`](docs/04-TESTING.md) per l'elenco dei 20 scenari richiesti, le fixture e l'esito reale di ogni esecuzione.

## Contribuire / licenza

MIT (`LICENSE`). Le dipendenze e i riferimenti studiati sono elencati in `docs/03-LICENSES.md`.
