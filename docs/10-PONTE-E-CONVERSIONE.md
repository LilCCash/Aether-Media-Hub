# Il ponte sul telefono e la conversione al volo degli MKV (1.2)

Questo documento spiega due cose nuove della 1.2, **che cosa è stato verificato davvero** e che cosa no.

* **Il ponte** («relay»): il telefono scarica il video con la tua chiave e lo ridà al televisore su un indirizzo suo, senza chiave. Così un link TorBox non finisce mai nelle mani del televisore.
* **La conversione al volo** («remux») degli MKV: il telefono rimette video e audio di un MKV (senza ricodificarli) in pezzi HLS/fMP4 che AVPlayer, AirPlay e Google Cast leggono. Serve per Picture in Picture, AirPlay con video e Google Cast con gli MKV.

Niente di quanto segue è stato provato con un televisore o un iPhone veri: nel sandbox di sviluppo non ci sono né l'uno né l'altro, e l'unico compilatore è quello del runner GitHub (macOS, simulatore). Vedi «Cosa è verificato».

## 1. Il ponte

```
televisore ──http──▶ iPhone (NWListener sull'indirizzo Wi‑Fi)  /r/<token di 64 caratteri>/<file>
                          │  legge a finestre da 4 MiB (Range)
                          ▼
                      sorgente reale (CDN, TorBox…): l'indirizzo e le intestazioni restano nel telefono
```

* **Si accende solo quando serve**: nessuna porta aperta e nessuna richiesta del permesso «Rete locale» finché non trasmetti qualcosa che passa dal ponte; si spegne 30 s dopo l'ultima sessione.
* **Chi può parlarci**: solo i dispositivi della stessa rete Wi‑Fi (la maschera del telefono); chiunque altro viene scollegato senza risposta. Una sessione può essere legata all'indirizzo del televisore.
* **Il segreto è l'indirizzo**: 256 bit casuali; il registro tiene solo lo SHA‑256 del token. Un indirizzo sbagliato, scaduto, revocato o di un altro file dà sempre la stessa risposta 404 (stessi byte).
* **Protezione dalla sorgente**: solo `https` (e `http` solo per un server della tua rete, con il permesso attivo); mai `127.0.0.1`, indirizzi di collegamento locale, multicast o il telefono stesso; ogni risposta DNS deve essere interamente pubblica; al più 3 reindirizzamenti, mai da https a http; le intestazioni dell'addon vanno solo all'origine esatta, non a dove ti reindirizza.
* **Fine di una sessione**: stop, cambio di televisore, la sorgente che risponde 401/403/404/410 (link scaduto), cambio di rete, scadenza (nessuna richiesta in 3 minuti; 12 ore al massimo). Il telefono chiude la connessione con garbo e, dopo 2 s, con la forza.
* **Impostazione «Invia il link diretto al televisore»** (Impostazioni › Avanzate, spenta): è l'unico modo di dare al televisore un link con la chiave. Non viene mai ripristinata da un backup e, se la spegni mentre trasmetti così, la trasmissione si ferma.
* Con il permesso «Rete locale» spento il ponte non esiste, e le trasmissioni che ci passavano si fermano.

## 2. La conversione al volo (MKV → HLS)

FFmpeg (già dentro MPVKit, licenza LGPL) legge l'MKV a finestre, trova i fotogrammi chiave nell'indice (Cues) e produce, **a richiesta**, questi file:

| File | Contenuto |
|---|---|
| `index.m3u8` | playlist master con `CODECS`, `RESOLUTION`, `FRAME-RATE`, `VIDEO-RANGE` |
| `media.m3u8` | playlist VOD con un pezzo ogni ~6 s, tagliati sui fotogrammi chiave del file |
| `init.mp4` | `ftyp` + `moov` (senza liste di modifica) |
| `seg-N.m4s` | `moof` + `mdat` di un pezzo, con i tempi di decodifica assoluti |

* **Cosa si copia**: video H.264 (8 bit) o HEVC (fino a 10 bit, etichetta `hvc1`); **una** traccia audio AAC, AC‑3, E‑AC‑3 o MP3. Niente viene decodificato o ricodificato: la qualità è quella del file.
* **Una traccia audio alla volta**: un file con più tracce audio nello stesso flusso ne fa suonare una sola e le altre non si possono scegliere dal televisore. Aether sceglie la lingua giusta (prima quella scelta a mano per il titolo, poi le impostazioni); per cambiarla dal pannello **Audio** il telefono riconverte da quel punto.
* **Cosa non passa**: audio DTS / TrueHD (se è l'unico audio il file è rifiutato con un messaggio; se ce ne sono altri passano quelli), sottotitoli incorporati (usa quelli di Aether), video VP9/AV1/MPEG‑2/Xvid/VC‑1 o a più di 10 bit.
* **Dolby Vision**: il profilo 5 è rifiutato (colori sbagliati senza il lettore Dolby); il profilo 7 (Blu‑ray) passa come HDR10, senza il secondo livello che i decoder Apple non leggono; i profili 8.x restano segnalati.
* **Tempi**: ogni pezzo ha un muxer nuovo; il tempo di decodifica reale è rimesso nel pezzo dopo. Per i file con fotogrammi B tutti i tempi sono spostati di (ritardo + 1) fotogrammi, uguale per video e audio, così che i tempi di decodifica non superino mai quelli di presentazione.
* **Quando serve un indice**: un MKV senza Cues non si può tagliare a fotogrammi chiave senza leggerlo tutto: è rifiutato con un messaggio (e con «Automatico» Aether passa a MPV).

## 3. Dove entra nell'app

| Caso | Cosa succede |
|---|---|
| **Impostazioni › Riproduzione › Player = «AVPlayer»** | gli MKV passano dalla conversione (prima davano «AVPlayer non apre i file MKV») |
| **«Automatico» + «Converti i file MKV per AVPlayer»** (spento di default) | anche in automatico gli MKV vanno ad AVPlayer; se il file non è convertibile Aether passa a MPV e lo dice |
| **Player = MPV** | nulla cambia |
| **Google Cast + MKV** (impostazione «Converti gli MKV per Google Cast», accesa) | il telefono converte e passa dal ponte; se il file non si può convertire, Aether lo invia com'è, come prima, e lo dice |
| **DLNA** | nessuna conversione (molti televisori DLNA leggono l'MKV; HLS è poco supportato) |
| **AirPlay con un MKV convertito** | all'apertura del selettore AirPlay il telefono sposta il file dal suo indirizzo interno (`127.0.0.1`, che il televisore non raggiunge) al ponte sull'indirizzo Wi‑Fi e riprende dallo stesso punto |

Per la riproduzione sul telefono i pezzi sono serviti da un piccolo server che ascolta **solo su `127.0.0.1`**: non servono né Wi‑Fi né il permesso «Rete locale». Picture in Picture funziona perché il motore è AVPlayer.

**AirPlay e link con chiave.** Con AVPlayer, AirPlay consegna al televisore l'*indirizzo* del video. Un link TorBox contiene la tua chiave: finché ne suona uno, Aether tiene il video fuori da AirPlay (il suono va, l'immagine resta sul telefono) e lo dice, a meno che tu non abbia acceso «Invia il link diretto». Un MKV convertito passa invece dal ponte, quindi il televisore non vede la chiave.

## 4. Cosa è verificato e cosa no

**Verificato (CI su macOS, simulatore):**

* Il ponte: parser HTTP, intestazioni, registro delle sessioni, regole contro l'accesso a indirizzi interni, finestre di lettura, server vero su `127.0.0.1` con un client TCP grezzo (risposte, Range, limiti di connessioni, richieste lente, revoca di una sessione, cancellazione di un lettore, rifiuto dei peer fuori dalla rete).
* La conversione: su **MKV veri** (generati con ffmpeg: H.264 con tre tracce audio, HEVC 10 bit con E‑AC‑3, DTS, VP9) il motore FFmpeg produce `init` e pezzi coerenti (tempi continui tra un pezzo e il successivo, stesso pezzo se richiesto due volte o fuori ordine, rifiuti con il motivo giusto).
* **Il lettore di sistema legge l'HLS prodotto**: nei test dell'app un `AVPlayerItem` apre lo stream servito dal server vero, ne legge durata e dimensioni e **riproduce attraverso il confine tra il primo e il secondo pezzo** (simulatore iOS).
* Le regole di scelta (motore, traccia audio, quale file si converte, compatibilità Cast) e i servizi (relay, conversione locale, coordinatore Cast) con motori finti.

**Non verificato (serve un dispositivo vero):**

* Che un televisore o un Chromecast raggiungano il telefono (isolamento dei client sul router, permesso «Rete locale», VPN) e che accettino l'HLS/fMP4 prodotto; AirPlay 2 di televisori Samsung/LG che prendono l'indirizzo dal telefono.
* Sincronia audio/video su file veri con fotogrammi B (ha test su fixture brevi e una correzione dopo la revisione), file con GOP aperti, audio che inizia in ritardo.
* Cosa fa iOS al ponte con lo schermo bloccato o l'app in background (la trasmissione può interrompersi), consumo di batteria e calore con 4K.
* La velocità del CDN di TorBox con richieste a intervalli (le finestre sono da 4 MiB, due in volo).
* Il Dolby Vision (nessun file reale): la lettura del profilo dai metadati del flusso è nuova e provata solo dalla compilazione.

## 5. Revisione del codice

Prima del rilascio il ponte e la conversione sono stati riletti da revisori indipendenti (più «lenti»: sicurezza, concorrenza, correttezza della conversione, integrazione, test) con una verifica avversaria di ogni segnalazione. Delle 28 confermate, quelle che toccavano la correttezza e la sicurezza sono state corrette: liste di modifica che sfasavano l'audio nei file con fotogrammi B, crash possibile creando una richiesta su una sessione già chiusa, più listener avviati insieme, finestre di download che continuavano dopo uno stop, task in background non chiuso in tempo, AirPlay che avrebbe consegnato un link con chiave, tracce senza campioni in un pezzo, primo fotogramma chiave tardivo, profilo Dolby Vision mai letto, un messaggio sul telefono sbagliato quando il televisore non risponde. Restano note e basse: i 4 slot di connessione condivisi con chi non ha ancora mostrato il token, e il fatto che la verifica DNS e quella di URLSession sono due risoluzioni distinte (finestra di «rebinding» ridotta ma non nulla), documentate nel codice.
