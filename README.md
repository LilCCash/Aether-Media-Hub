# Aether — media center per iPhone

Aether è un media center nativo (Swift / SwiftUI) per iPhone che parla il **protocollo degli addon Stremio**.
È un progetto indipendente: codice, nome, interfaccia e icona sono originali (vedi [`NOTICE`](NOTICE) e [`docs/03-LICENSES.md`](docs/03-LICENSES.md)).
Non fornisce contenuti: mostra e riproduce ciò che gli addon installati dall'utente restituiscono.

> **Stato in una riga (1.0 Beta 3):** il codice compila e i test automatici girano su macOS in CI; **non è stato provato su un iPhone fisico**, non esiste un IPA firmato (il workflow *Build IPA* compone un IPA **non firmato**, da firmare con il tuo Apple ID; nel repository non sono configurate credenziali di firma), e molte funzioni (AirPlay, Google Cast, DLNA, VoiceOver, Picture in Picture, aspetto reale di HDR/Dolby Vision, **TMDB e TheTVDB con un account reale**) sono implementate ma **non verificate con hardware o servizi reali**; per TorBox, con la Beta 1 la verifica della cache, l'aggiunta e la richiesta del link hanno funzionato su un account reale (segnalazione dell'utente), mentre l'avvio del video dopo le correzioni della Beta 2 è ancora da confermare. Il dettaglio onesto è in [Stato reale](#stato-reale) e in [`docs/04-TESTING.md`](docs/04-TESTING.md); le note di questa versione sono in [`docs/release-notes/v1.0.0-beta.3.md`](docs/release-notes/v1.0.0-beta.3.md) e, per i problemi noti dell'audit, in [`docs/08-ALPHA-2-NOTE.md`](docs/08-ALPHA-2-NOTE.md).

## Documentazione

| Documento | Contenuto |
|---|---|
| [`docs/01-RESEARCH-MATRIX.md`](docs/01-RESEARCH-MATRIX.md) | Fase 1: ricerca su Stremio/Nuvio, matrice delle funzioni, licenze, limiti iOS |
| [`docs/02-ARCHITECTURE.md`](docs/02-ARCHITECTURE.md) | Architettura, moduli, sicurezza |
| [`docs/03-LICENSES.md`](docs/03-LICENSES.md) | Licenza e obblighi di ogni dipendenza |
| [`docs/04-TESTING.md`](docs/04-TESTING.md) | Scenari di test, fixture, cosa è stato davvero eseguito |
| [`docs/05-SUBTITLES-RESEARCH.md`](docs/05-SUBTITLES-RESEARCH.md) | Ricerca sui sottotitoli da addon (OpenSubtitles) e decisioni |
| [`docs/06-PLAYBACK.md`](docs/06-PLAYBACK.md) | Motori di riproduzione, HDR / Dolby Vision, matrice di test e limiti |
| [`docs/07-SERVIZI.md`](docs/07-SERVIZI.md) | TorBox, TMDB, TheTVDB, OpenSubtitles: cosa è verificato e cosa no |
| [`docs/08-ALPHA-2-NOTE.md`](docs/08-ALPHA-2-NOTE.md) | Note di rilascio di Alpha 2 e problemi noti |

## Struttura

```
Packages/AetherCore   Libreria Swift solo-Foundation: protocollo addon, rete sicura, ricerca, libreria,
                      backup, analisi stream, sottotitoli, UPnP, download, impostazioni (testata con `swift test`)
App/Aether            App SwiftUI (MVVM): Home, Scopri, Cerca, Libreria, Download, Addon, Player, Casting, Impostazioni
App/AetherTests       Test unitari dell'app (impostazioni, router, Portachiavi…)
App/AetherUITests     Test UI contro un server di addon di prova (Tools/FixtureAddonServer)
Tools/                Server di prova per i test UI: addon Stremio (con finti TMDB/TheTVDB e file della matrice media) e TorBox
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

> **Costo dei minuti:** finché il repository era privato i minuti dei runner macOS contavano 10× e dopo molte esecuzioni da ~15 minuti i job hanno smesso di partire (quota esaurita); con il repository pubblico i runner sono gratuiti e hanno ripreso a funzionare. Per tenere la CI veloce i test UI (~15 minuti) girano solo su `main` e sulle esecuzioni manuali; gli altri push compilano e lanciano i test unitari, e le modifiche alla sola documentazione non avviano la CI.

Il workflow **Build IPA** (`.github/workflows/build-ipa.yml`) compone il file `.ipa` sui runner macOS di GitHub. Si avvia da *Actions ▸ Build IPA ▸ Run workflow* (anche via API), quando spingi un tag `v*` e quando il file del workflow cambia.

| Modalità | Credenziali | Risultato | Stato |
|---|---|---|---|
| **Non firmato** (predefinita) | nessuna | artefatto `Aether-unsigned-ipa` con `Aether-unsigned.ipa` (arm64, Release, ~20 MB compresso: include MPVKit/FFmpeg); per pubblicarlo come *pre-release* di GitHub: esecuzione manuale con `publish_release` e un `release_tag` (es. `v1.0.0-alpha.2`), oppure push di un tag `v*`; se il tag non esiste viene creato sul commit compilato | ✅ eseguito in CI, anche dopo le correzioni della revisione: archivio Release per iPhone e pacchetto verificato (bundle id, versione 1.0.0 e build number presi dalla configurazione, deployment target, binario solo arm64 per dispositivo, Google Cast SDK incorporato, icona nel catalogo, privacy manifest, schemi `aether` e `stremio`, nessuna firma) |
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
| Analisi delle sorgenti (qualità, codec, HDR, audio, lingue, dimensione) e ordinamento; sorgenti non riproducibili segnalate prima della riproduzione; i badge ricavati dal **nome** sono etichettati «(nel nome)» | ✅ |
| AVPlayer: MP4/MOV/M4V/HLS, ripresa, salto avanti/indietro, velocità, gesti, blocco controlli, timer di spegnimento, riempi schermo | 🟡 |
| **MPV (MPVKit, LGPL)** come secondo motore: MKV, AVI, TS… Il motore è scelto da **fatti letti dal file**, non dai nomi; se non apre il file si passa **una volta** all'altro motore riprendendo dalla stessa posizione | ✅ i file della matrice (H.264 MKV/AVI, HEVC HDR10/HLG, hev1) si riproducono nel simulatore in CI · 🟡 su iPhone |
| HDR10 / HLG / Dolby Vision: rilevati dal file (box `hvcC`/`dvcC`/`dvvC`, primarie/trasferimento, `isDecodable`) e mostrati nel foglio «Informazioni sulla sorgente» separando *dichiarato*, *rilevato* e *atteso*. **Vero Dolby Vision solo con AVPlayer** (MP4/MOV/HLS); con MPV un file Dolby Vision è mappato su HDR10/SDR e descritto così, mai come Dolby Vision | ✅ logica con vettori costruiti dalla specifica · 🟡 l'aspetto su uno schermo HDR e i file Dolby Vision reali non sono stati provati (nessun encoder né dispositivo) — vedi [`docs/06-PLAYBACK.md`](docs/06-PLAYBACK.md) |
| Impostazioni del player (Riproduzione): motore, uscita HDR, tone mapping, decodifica hardware, deband, luminosità/contrasto/saturazione/gamma, buffer, lingue audio/sottotitoli primarie e secondarie, tenere premuto per accelerare, pulizia dei sottotitoli per non udenti | ✅ (modello e logica) · 🟡 (resa sul dispositivo) |
| Sottotitoli esterni SRT/VTT/ASS con rilevamento codifica, ritardo regolabile, stile persistente, importazione da file; tracce audio e sottotitoli incorporati | ✅ (parser) · 🟡 (resa nel player) |
| **Sottotitoli da addon** (OpenSubtitles v3 consigliato in Addon, mai installato da solo): ricerca con nome file e hash calcolato sul dispositivo, classifica per lingua, gruppi per lingua con filtro, scelta automatica, lingua ricordata per la serie, stati vuoti ed errori onesti | ✅ logica Core · 🟡 interfaccia (alcuni test UI non passano: vedi `docs/04-TESTING.md`) |
| Episodio successivo con prefetch delle sorgenti, conto alla rovescia, riproduzione automatica, continuità del gruppo di rilascio | ✅ (logica) · 🟡 (player) |
| Picture in Picture, audio in background, schermata di blocco (Now Playing), interruzioni (telefonate), ripresa dopo perdita di rete | 🟡 |
| DASH, YouTube nel player, torrent integrato | ❌ (segnalati come non riproducibili; i torrent si riproducono solo tramite TorBox) |
| Verifica dei certificati TLS dei flussi riprodotti da MPV | ❌ **libmpv non verifica i certificati** nella configurazione attuale (comportamento predefinito di mpv); AVPlayer sì. Problema noto, vedi `docs/08-ALPHA-2-NOTE.md` |

### Servizi con la tua chiave (facoltativi)
| Funzione | Stato |
|---|---|
| **TorBox**: chiave nel Portachiavi, verifica della connessione, controllo cache («In cache» / «Non in cache», mai «non in cache» se la verifica è fallita), riproduzione di un torrent già in cache, download su conferma esplicita con avanzamento, nessuna cancellazione automatica | ✅ Core con stub HTTP e test UI contro un server di prova · 🟡 **TorBox reale non è stato mai contattato** |
| **TMDB** e **TheTVDB**: completano locandina, sfondo, logo, trama, cast, durata, titoli degli episodi **solo dove l'addon non li ha**, non sovrascrivono mai i dati dell'addon, mostrano l'attribuzione | ✅ Core con stub HTTP · 🟡 con una chiave reale non provato; logo TMDB non incluso (solo il testo di attribuzione) |

### Cerca e Scopri
| Funzione | Stato |
|---|---|
| Cerca: menu **Tipo** (Film, Serie TV e ogni altro tipo fornito dagli addon: TV, sport…), **Genere**, **Anno**, ordinamento; il filtro è mandato all'addon solo se il suo manifest lo dichiara, altrimenti è locale e l'interfaccia dice quanti risultati nasconde | ✅ Core e logica dell'app · 🟡 interfaccia (test UI in parte non passati) |
| Scopri: tipi dinamici dagli addon, menu catalogo/genere/anno, e in *Impostazioni ▸ Aspetto ▸ Categorie di Scopri* mostra/nascondi e ordina | ✅ Core e logica dell'app · 🟡 interfaccia |

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

Ultimo risultato completo in CI (macOS, Xcode 26.6, simulatore iPhone, iOS SDK 26.5) sul commit `57a5a04`; la release Alpha 2 è costruita da `4ff1d3b`, che aggiunge le correzioni dell'audit **compilate** dal workflow *Build IPA* ma i cui test non sono stati rieseguiti:

| Suite | Test | Esito |
|---|---|---|
| AetherCore (`swift test`) | 540 | tutti passati |
| Unit dell'app | 222 | tutti passati |
| UI contro addon di fixture | esecuzione interrotta dopo 90 minuti (ora divisa in gruppi paralleli) | molti passati (layout, esplorazione, addon, download, ripresa, cronologia, parte dei sottotitoli); **diversi non passano** — elenco e cause in [`docs/04-TESTING.md`](docs/04-TESTING.md) |

[`docs/04-TESTING.md`](docs/04-TESTING.md) mappa ciascuno dei 20 scenari richiesti sul test che lo verifica e dice quali **non** sono stati eseguiti su hardware reale (AirPlay, Google Cast su Chromecast/Android TV, VoiceOver su dispositivo, DLNA su televisori, rete mobile).

## Contribuire / licenza

MIT (`LICENSE`). Le dipendenze e i riferimenti studiati sono elencati in `docs/03-LICENSES.md`.
