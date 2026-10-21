# Riproduzione: motori, HDR / Dolby Vision, formati e cosa è stato davvero verificato

Questo documento descrive la catena di riproduzione di Aether Alpha 2, perché in Alpha 1 «il Dolby Vision non si vedeva», quali motori sono stati valutati,
cosa fa ciascuno con HDR e Dolby Vision, e la matrice di test con l'esito reale. **Nessuna prova è stata fatta su un iPhone fisico**: tutto ciò che riguarda
l'aspetto delle immagini su uno schermo HDR resta non verificato (vedi «Limiti»).

## 1. La catena

```
sorgente (addon / debrid / download)
  └─ StreamAnalyzer ........ contenitore dall'URL o da behaviorHints.filename; i token del nome («DV», «HDR10») sono solo DICHIARAZIONI
       └─ PlaybackPlanner .. sceglie il motore da fatti, non da nomi (container + MediaFormatInfo + DeviceVideoCapabilities)
            ├─ AVPlayerEngine ... MP4 / MOV / M4V / HLS · vero Dolby Vision (profili 5, 8.1, 8.2, 8.4)
            └─ MPVEngine ........ MKV / AVI / WebM / TS / FLV / … · HDR10 / HLG · Dolby Vision mappato su HDR10 o SDR
```

* **Fatti, non nomi.** `MediaProbe` (AVFoundation) legge dal file: il codice del sample entry (`hvc1`, `hev1`, `dvh1`, …), le primarie / il trasferimento colore, i box
  `hvcC` / `dvcC` / `dvvC` (profilo e livello Dolby Vision, profondità di bit), `AVAssetTrack.isDecodable` e il flag `containsHDRVideo`. `MPVFactsReader` fa lo stesso con le proprietà di mpv
  (`video-params/*`, `track-list/N/dolby-vision-profile`, `hwdec-current`, `vo-configured`). Il badge «Dolby Vision 8.1» compare solo se un decoder lo ha letto; un nome che dice «DV»
  resta «Dolby Vision (nel nome)».
* **Scelta del motore** (`PlaybackPlanner`, con test unitari): contenitore non nativo → MPV; traccia che iOS dichiara non decodificabile (per esempio HEVC marcato `hev1`) → MPV;
  Dolby Vision profilo 7 (doppio strato, UHD Blu-ray, non decodificabile dai decoder Apple) → MPV; Dolby Vision 5/8.x in MP4/MOV/HLS → AVPlayer. Se la scelta iniziale (fatta senza aver
  letto il file) risulta sbagliata, o un motore non riesce ad aprire il file (formato/codec/uscita video), Aether passa **una volta** all'altro motore riprendendo dalla stessa posizione.
  Gli errori di rete non cambiano motore.
* **Uscita attesa.** L'info sheet del player separa tre cose: *dichiarato* (addon / nome), *rilevato* (decoder) e *atteso* (stima dal formato e dallo schermo). Con MPV un file Dolby Vision
  è sempre descritto come «HDR10 ricavato dal Dolby Vision» o «SDR con tone mapping», mai come Dolby Vision.

## 2. Perché in Alpha 1 il Dolby Vision (e spesso l'HDR) «non si vedeva»

Cause trovate leggendo il codice e le specifiche, non ipotesi sull'iPhone dell'utente:

1. **Nessuna logica HDR**: `StreamAnalyzer` produceva solo badge dai token del nome; nulla leggeva il file né verificava lo schermo.
2. **MKV rifiutato**: quasi tutte le release HDR/Dolby Vision circolano in Matroska; AVPlayer non apre MKV, quindi la sorgente era marcata «non riproducibile» o falliva.
3. **HEVC `hev1`**: gli x265 «predefiniti» marcano `hev1` anche in MP4; i decoder Apple richiedono `hvc1`, e il risultato tipico è audio senza immagine.
4. **Dolby Vision profilo 7** (Blu-ray, strato di miglioramento): non decodificabile dai decoder Apple.
5. Nessun messaggio onesto: il giocatore non diceva mai cosa stava succedendo.

Alpha 2 affronta 2–5 con un secondo motore e con il probe; l'immagine di un file Dolby Vision profilo 5/8 in MP4 passa ancora dal percorso di sistema, che è l'unico in grado di
pilotare lo schermo in Dolby Vision.

## 3. Motori valutati (fonti primarie lette il 2026-10-20 dal runner GitHub: `API probe`)

| Motore | Licenza | Piattaforme / requisiti | Cosa offre per questo scopo | Decisione |
|---|---|---|---|---|
| **AVPlayer** (Apple) | parte di iOS | — | HLS, MP4/MOV, HEVC, vero Dolby Vision (5, 8.x), PiP, AirPlay video | **Incluso** (predefinito per i contenitori nativi) |
| **MPVKit** 1.0.0 → libmpv + FFmpeg (prodotto LGPL) | **LGPL-3.0** (il prodotto `-GPL` è GPL e non è usato) | iOS ≥ 15 (Aether: 17), binari XCFramework con slice dispositivo e simulatore | Matroska/AVI/TS/…, decoder hevc/h264/av1/vp9/vc1/mpeg2, audio ac3/eac3/truehd/dca/opus/flac, sottotitoli ass/pgs/srt; libplacebo + libdovi per mappare HDR10/Dolby Vision; è lo stesso motore usato da Nuvio su iOS | **Incluso** (secondo motore) |
| **AetherEngine** (`superuser404notfound/AetherEngine`) | LGPL-3.0 + «App Store Exception» (testo personalizzato, GitHub lo classifica «Other») | **iOS ≥ 18**, Swift tools 6.1 | FFmpeg demux + VideoToolbox, HDR10/HDR10+/Dolby Vision/HLG, molti contenitori; il README di MPVKit lo raccomanda per la produzione; progetto attivo (ultimo push il giorno del controllo) | **Non incluso**: richiede di alzare il minimo a iOS 18 e non è verificabile qui su dispositivo. È il candidato naturale per un vero Dolby Vision da MKV (vedi «Prossimi passi») |
| KSPlayer | GPL-3.0 (versione LGPL a pagamento; DV profili 5/7/8 «nativo» è una funzione a pagamento) | Apple | — | Escluso: la GPL cambierebbe la licenza dell'app |
| VLCKit / MobileVLCKit | LGPL-2.1+ (il repository `vlc-ios` risulta «Other») | iOS | Molti formati; nessun HDR/Dolby Vision documentato | Escluso: stesse dimensioni di MPV, meno controllo sull'HDR |

Nota di onestà sul README di MPVKit: «MPVKit is only suitable for learning libmpv and will not be maintained too frequently». Aether lo pinna alla versione stabile `1.0.0` e lo usa solo dove AVPlayer
non può arrivare; se il motore non parte (per esempio nessun dispositivo Metal), Aether lo dice e, quando il contenitore lo permette, ripiega su AVPlayer.

### 3.1 Cosa contengono le librerie (verificato sui binari XCFramework 1.0.0, slice iOS arm64)

* Demuxer FFmpeg: `matroska` (anche WebM), `avi`, `mov`, `mpegts`/`mpegtsraw`, `mpegps`, `flv`, `asf`, `ogg`, `rm`, `hls`, `dash`, `ape`, `flac`, `wav`, `aiff`, …
* Decoder: video `hevc`, `h264`, `av1` (+ `libdav1d`), `vp9`, `vp8`, `vc1`, `mpeg1/2/4`, `prores`, `wmv*`, `rv*`; audio `aac`, `ac3`, `eac3` (+ varianti AudioToolbox), `truehd`, `dca`, `opus`, `vorbis`, `flac`, `alac`, `mp3`, `pcm_*`; sottotitoli `subrip`, `ass`, `webvtt`, `movtext`, `pgssub`, `dvdsub`, `dvbsub`.
* Il test unitario `PlaybackEngineTests.testLibmpvStartsAndReportsItsCodecsAndContainers` rilegge queste liste dalla libreria in esecuzione (slice simulatore) a ogni CI.

## 4. HDR e Dolby Vision con MPV: cosa fa e cosa no

Dalla documentazione di mpv (opzioni `--target-colorspace-hint`, `--tone-mapping`, `--hdr-compute-peak`):

* Con `target-colorspace-hint=yes` e il layer Metal con `wantsExtendedDynamicRangeContent`, il segnale HDR10/HLG è inviato allo schermo che lo supporta; altrimenti mpv fa tone mapping verso SDR (curva a scelta in Impostazioni).
* mpv **«non invia i metadati completi HDR10+ o Dolby Vision»**: li usa per produrre un segnale HDR10. Per il Dolby Vision profili 5/7/8 (riscalatura RPU tramite libdovi/libplacebo) il risultato è una
  conversione, non lo schermo in modalità Dolby Vision.
* Quindi: **vero Dolby Vision solo con AVPlayer** (MP4/MOV/HLS con profili 5, 8.1, 8.2, 8.4). Un MKV Dolby Vision si vede, correttamente colorato come HDR10 o SDR, ma non «in Dolby Vision».

## 5. Matrice di test

Legenda: ✅ eseguito in CI con esito positivo · 🟡 coperto solo in parte · ⛔ non eseguibile qui (richiede hardware / contenuti reali) · — non applicabile.
La colonna «Come» dice cosa dimostra il test. I file della matrice sono generati in CI con ffmpeg (immagini sintetiche; il segnale colore e i tag sono reali, i pixel no).

(gli esiti reali dell'ultima esecuzione sono nella sezione 7)

## 6. Limiti dichiarati

* **Nessun test su iPhone fisico**: l'aspetto reale di HDR10 / HLG / Dolby Vision, la luminosità di picco, la resa del tone mapping, il consumo, la fluidità a 4K e le prestazioni della decodifica software di AV1/VP9 non sono verificati.
* L'uscita video di MPV (Metal via MoltenVK) è provata in CI solo nella misura indicata dalla matrice; la patch Metal di mpv è non ufficiale (lo dice il README di MPVKit).
* Dolby Vision: l'analisi dei box `dvcC`/`dvvC` è provata con vettori costruiti dalla specifica (test unitari), **non** con file Dolby Vision reali (nessun encoder disponibile in CI). Dolby Vision profilo 7 FEL non ha un percorso nativo.
* Il Picture-in-Picture è solo AVPlayer. Con MPV l'audio continua in background (il video viene sospeso), ma non c'è PiP.
* Dolby Atmos: AVPlayer lo riproduce se il file lo contiene e l'uscita lo supporta; con MPV E-AC-3/TrueHD sono decodificati a canali (nessun oggetto). Non verificato su dispositivo.
* DASH (`.mpd`) resta «non supportato»: FFmpeg lo apre, ma non è stato provato.

## 7. Esito dell'ultima esecuzione

Ultima esecuzione della matrice (CI, commit `57a5a04`, simulatore, file generati da ffmpeg; riproduzione = la posizione supera 2 s):

| File | Motore scelto | Riproduzione | Fatti mostrati nel foglio Informazioni |
|---|---|---|---|
| H.264 in Matroska | MPV | ✅ | solo contenitore e motore (codec/gamma non visti) |
| H.264 in AVI | MPV (atteso) | ❌ «il player non si apre» (causa non chiarita) | — |
| HEVC Main10 HDR10 in MP4 | AVPlayer | ✅ | solo contenitore e motore |
| HEVC Main10 HDR10 in MKV | MPV | ✅ | solo contenitore e motore |
| HEVC Main10 HLG in MP4 | AVPlayer (atteso) | ❌ «il player non si apre» | — |
| HEVC `hev1` HDR10 in MP4 | MPV (il pianificatore sceglie MPV) | ✅ | contenitore e motore |
| HEVC 8 bit in MP4 | AVPlayer | ✅ | solo contenitore e motore |
| uscita video reale di MPV (Metal/MoltenVK) | — | non confermata (test non passato) | — |

Quindi: la **scelta del motore** e la **riproduzione** dei file sopra sono osservate; il **rilevamento reale di HDR10/HLG nel simulatore non è confermato** (le righe «Video» e «Gamma dinamica» non compaiono nel foglio durante il test), e **Dolby Vision non è stato provato** (nessun file). La logica di lettura dei box e di classificazione ha test unitari con vettori costruiti dalla specifica. Una nuova esecuzione con i test corretti era in corso alla pubblicazione.

## 8. Prossimi passi consigliati

1. Provare su un iPhone con file Dolby Vision reali (profili 5, 8.1, 7) e documentare cosa mostra ciascun motore.
2. Valutare AetherEngine come terzo motore (alzando il minimo a iOS 18) per il vero Dolby Vision da MKV tramite VideoToolbox.
3. Aggiungere un remux al volo MKV → fMP4/HLS verso AVPlayer solo se la valutazione precedente non basta.
