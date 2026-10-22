# Cosa provare in Aether 1.2 Beta 1 (e come)

Lista pensata per chi prova l'IPA su un iPhone vero (anche in LiveContainer). Per ogni prova: **Come** si fa, **Deve succedere** cosa vedere, **Se non va** cosa mi serve sapere.
Le prove sono ordinate dalle più importanti (cose nuove o mai viste su un telefono) alle più normali. Segna accanto a ciascuna ✅ / ❌ / ➖ (non applicabile).

Ogni nome di pulsante, percorso e valore predefinito qui sotto è stato controllato riga per riga contro il codice dell'app (59 correzioni rispetto alla prima stesura). Quello che **non** si può sapere dal codice (cosa fa iOS, cosa fa il tuo televisore) è scritto come tale.

**Prima di cominciare**
- Installa l'IPA firmato da te (AltStore, Sideloadly). Se usi **LiveContainer** annotalo: Picture in Picture, Cast e il permesso «Rete locale» possono comportarsi in modo diverso. Per le prove da 6 a 9 (PiP, MKV convertiti, AirPlay, Cast) conviene un'installazione diretta.
- **Accendi «Consenti rete locale»**: *Altro › Impostazioni › Account e dati › Privacy › «Consenti rete locale (addon, sorgenti, Cast)»*. È **spento di default** e senza di esso Cast, ponte e AirPlay con MKV convertito non funzionano.
- Accendi il registro dettagliato: *Altro › Impostazioni › Avanzate › Diagnostica › Registro dettagliato*. Il registro normale è già attivo (finché «Conserva il log diagnostico (solo su questo dispositivo)» in *Account e dati* è acceso, lo è di default). **Attenzione: il registro vive solo finché l'app è aperta**; se Aether si chiude o riparte (in LiveContainer capita) si azzera. Appena qualcosa non va, torna in *Avanzate › Diagnostica*, tocca **Mostra il registro** e mandami il testo (non contiene chiavi né indirizzi completi).
- Ti servono: almeno un addon di cataloghi (Cinemeta) e uno di sorgenti; meglio due addon di sorgenti (prove 3 e 4); una chiave TMDB (gratuita su themoviedb.org › Impostazioni › API) e, se ce l'hai, TorBox; per Cast/AirPlay, un televisore sulla stessa rete Wi‑Fi.

---

## 1. Backup e ripristino (il difetto che hai trovato) — **PROVA SUBITO**
1. *Altro › Impostazioni › Account e dati › Backup e ripristino.* Se vuoi, accendi **Includi gli indirizzi degli addon** (spento di default: senza, gli addon vanno reinstallati a mano). Tocca **Crea backup…**, poi **Condividi Aether-Backup-….json** e salva il file in *File › Sul mio iPhone* (o iCloud Drive).
2. Aggiungi un titolo alla Watchlist o guarda 20 secondi di un video, così i dati cambiano.
3. Tocca **Ripristina da file…** e scegli il file salvato.
   - **Deve succedere:** il file si apre (nessun file è «grigio»: ora si può scegliere qualunque file) e **nella pagina** compare la sezione **«Backup scelto»** con il nome del file, un riepilogo («N titoli salvati · N punti di visione · N addon · impostazioni incluse»; se hai creato il backup senza gli indirizzi degli addon legge «N addon (N senza indirizzo: da reinstallare)») e sotto «Creato il <data> con Aether <versione>».
   - L'interruttore **Ripristina anche le impostazioni** è **acceso di default** (compare solo se il backup contiene le impostazioni): se lo spegni prima di toccare Unisci o Sostituisci, le impostazioni non cambiano.
   - Tocca **Unisci ai dati attuali** → «Ripristino completato: …» (la sezione «Backup scelto» sparisce).
   - Per provare **Sostituisci tutto…** (chiede conferma: «Sostituire i dati attuali?») e **Annulla**, scegli di nuovo il file con **Ripristina da file…**.
4. Prova anche con file che non sono backup. Un `.json` qualsiasi (un oggetto JSON senza i dati di Aether) deve dire «“nome.json”: Il file non è un backup di Aether.»; un'immagine o un file rotto dice «“nome”: Il file di backup è danneggiato.». «Non riesco ad aprire il file: …» (con il motivo, senza nome) compare solo se il file non si riesce proprio a leggere (permessi, file iCloud non scaricato); oltre 64 MB: «Il file è troppo grande per essere un backup di Aether.»
- **Se non va:** dimmi dove l'avevi salvato (File › Sul mio iPhone, iCloud Drive, cartella di un'altra app), se il file appare grigio nel selettore, e il messaggio che compare, per intero.

## 2. La scheda del titolo con i dati TMDB
**Senza chiave:** apri un film. **Deve succedere:** in fondo una riga «Aggiungi la tua chiave TMDB in Impostazioni › Servizi…».
**Con chiave:** *Impostazioni › Servizi › TMDB*: incolla la chiave → **Salva e verifica** (devono comparire «Il servizio accetta la chiave.» e «Chiave salvata nel Portachiavi»). Apri un film popolare (es. «Dune»).
- **Deve succedere** (a pezzi, scorrendo la scheda):
  - **Cast** con foto rotonde e nome del personaggio.
  - **Trailer**: elenco, ognuno si apre in YouTube. Il pulsante «film» sta **a destra del segnalibro** (accanto a Play): con un solo trailer lo apre direttamente in YouTube, con più trailer apre un menu (i trailer indicati dall'addon si chiamano «Trailer 1», «Trailer 2»…); senza trailer non c'è.
  - **Produzione** (loghi su tessera chiara).
  - **Budget** e **Incassi**: due riquadri senza titolo di sezione, ognuno solo se TMDB conosce la cifra; solo per i film.
  - **Dettagli**: Stato, Info rilascio, Durata, Certificazione, Paese (o Paesi), Lingua originale; le righe senza dato non compaiono; per le serie anche «Stagioni».
  - **Titoli simili**: toccane uno e si apre la sua scheda; se TMDB non indica il codice IMDb del titolo, o non risponde, compare l'avviso «Titolo non disponibile» («… TMDB non indica il suo codice IMDb oppure non risponde…»); mentre Aether cerca il codice i tocchi successivi sono ignorati.
  - In fondo «**Offerto da TMDB**» e l'avviso richiesto da TMDB.
- Apri una **serie**: niente Budget/Incassi; compaiono «Creato da» (solo se l'addon non indica già una «Regia»), la riga «Stagioni» in Dettagli («8 stagioni · 73 episodi») e i canali tra le produzioni.
- Attiva la modalità aereo (o spegni Wi‑Fi **e** dati cellulari) e riapri un titolo che hai già aperto con la chiave nelle ultime 24 ore: le sezioni TMDB compaiono dalla cache; se la cache è scaduta mancano, senza errori. (Serve «Salva in cache metadati e cataloghi» acceso in *Archiviazione*, lo è di default.)
- **Se non va:** dimmi quale sezione manca e il titolo; per «simili» il messaggio che compare.

## 3. Ordine delle sorgenti «Per addon» e pillola del formato
1. Con **due addon di sorgenti** (A sopra, B sotto): *Altro › Addon*, tocca **Modifica** e trascina per cambiare l'ordine.
2. Apri un titolo che entrambi hanno e tocca **Guarda**.
   - **Deve succedere:** nell'elenco «Sorgenti riproducibili» le sorgenti di **A vengono tutte prima** di quelle di B (dentro ogni addon: lingua, qualità, codec); le non riproducibili restano in fondo, nel gruppo chiuso «Non riproducibili su iOS». I chip degli addon in alto filtrano. Se hai TorBox, i torrent «In cache» possono salire davanti agli altri torrent anche di un altro addon.
3. *Impostazioni › Riproduzione › Sorgenti › Ordine delle sorgenti* → **Le migliori per prime**, poi riapri il titolo con **Guarda** (l'elenco si calcola all'apertura): ora ignora l'addon di provenienza ed è ordinato per lingua preferita, qualità e codec (una sorgente nella tua lingua può stare sopra una a qualità più alta). Rimetti «Per addon».
4. Attiva **Scegli automaticamente la sorgente migliore** e riapri il titolo: deve partire una sorgente del **primo addon** (se ha qualcosa di riproducibile).
5. **Pillola del formato:** su ogni sorgente di cui si riconosce il formato compare una pillola con il solo contorno: **MKV, AVI, MP4, MOV, M4V, TS, WEBM** (ma anche M2TS, WMV, FLV, MPEG, VOB…), **HLS** per le playlist `.m3u8` e **DASH** per `.mpd`. Viene dall'estensione del link o dal nome file dichiarato dall'addon; se non si riconosce non c'è. Con VoiceOver la riga della sorgente include «Formato MKV» nella lettura completa (non è un elemento separato su cui ci si ferma).
- **Se non va:** mandami nome dei due addon, ordine e cosa vedi.

## 4. Il player: pannelli laterali e pulsanti
Apri un MP4 (o qualunque sorgente) e fai partire il video.
- **Pulsanti sotto la barra di avanzamento:** Sottotitoli · Audio · Sorgenti (se ce ne sono altre) · Velocità · Riempi · Episodi (solo serie). Su schermo stretto mostrano solo le icone.
- **Sottotitoli:** tocca il pulsante. **Deve succedere:** a destra un pannello largo circa il 40% dello schermo in orizzontale (mai meno di 340 pt: in verticale, se hai spento «Riproduci sempre in orizzontale», occupa quasi tutta la larghezza). Il video resta visibile ma scurito e la tua scelta si applica subito; il sottotitolo in onda compare a sinistra del pannello, non scurito, così vedi l'effetto di ritardo e scelta. Due colonne:
  - **lingue** a sinistra: una riga per ogni lingua dei sottotitoli degli addon, con accanto il numero di sottotitoli disponibili; se le lingue sono almeno due compare anche «Tutte» (con il totale). Con una sola lingua c'è solo quella riga; senza nessun addon di sottotitoli c'è «Nessuna lingua».
  - **elenco** a destra: «Disattivati», le tracce incorporate, poi i sottotitoli degli addon con un'intestazione per ogni lingua e, in fondo, i file che hai importato (scritti «File locale»).
  - In basso: **− / +** ritardo, **Azzera**, **Importa**, **Stile**.
- **Audio:** elenco delle tracce con la spunta su quella attiva.
- **Sorgenti:** in alto la riga «In riproduzione» con la sorgente attuale, poi le alternative (i chip «Tutti» / nome addon compaiono solo se le alternative vengono da almeno due addon). Toccandone una il pannello si chiude e il video riparte con la nuova sorgente dallo stesso punto.
- **Aree di tocco:** i pulsanti − / + del ritardo e la ✕ hanno un'area di 44 pt. Con il testo grande (*Accessibilità*) il pannello dei sottotitoli scorre tutto insieme.
- **Per chiudere un pannello:** tocca la parte scura a sinistra o la **✕**. Con VoiceOver vale il gesto «Esci» (strofinio a forma di «Z» con due dita); attenzione: a pannello chiuso lo stesso gesto chiude il player.
- **Velocità:** pulsante con il menu delle velocità. **Riempi / Adatta:** riempie lo schermo o lo adatta.
- **Blocca i controlli:** icona del lucchetto in basso a sinistra, sotto la barra. Controlli e gesti si disattivano. Per sbloccare tocca lo schermo: in alto a destra compare per 2,5 secondi il pulsante «Sblocca», da toccare subito.
- **Timer di spegnimento:** menu ⋯ › Timer di spegnimento.
- **Gesti** (attivi di default; si spengono in *Riproduzione › Controlli › «Gesti (luminosità, volume, doppio tap)»*): trascina in verticale a sinistra = luminosità, a destra = volume; trascina in orizzontale = sposta il video avanti/indietro; doppio tocco a sinistra = indietro di 10 s, a destra = avanti di 10 s, al centro = pausa/riproduci; tenere premuto = accelera (velocità in *Riproduzione › Controlli*).
- **Se non va:** dimmi quale pannello, orientamento (verticale/orizzontale) e modello di iPhone; uno screenshot aiuta molto.

## 5. Sottotitoli
- **Da addon:** con un addon di sottotitoli (es. OpenSubtitles) apri il pannello: i sottotitoli compaiono raggruppati per lingua; per prima la lingua scelta in *Impostazioni › Riproduzione › Lingue › «Sottotitoli»* (di default è «Disattivati»: allora le lingue sono in ordine alfabetico). Sceglierne uno lo mostra dopo il tempo del download (di solito pochi secondi); se non arriva compare un errore con «Riprova».
- **Da file:** pannello › **Importa** (il pannello si chiude e si apre il selettore dei file) › scegli un `.srt` (vanno anche `.vtt`, `.ass`, `.ssa`): il sottotitolo si mostra subito. Riapri il pannello: in fondo all'elenco c'è una riga con il nome del file e la dicitura «File locale», con la spunta. Lo stesso comando è nel menu ⋯ › Importa sottotitoli….
- **Ritardo:** con le icone − / + (mezzo secondo per tocco; + li ritarda, − li anticipa) il testo si sposta e il valore al centro cambia; «Azzera» lo riporta a 0. Con AVPlayer (es. un MP4) funziona solo per i sottotitoli degli addon o importati, non per quelli incorporati (il pannello lo scrive in piccolo).
- **Stile:** pannello › **Stile** apre un foglio con un'anteprima in alto che cambia subito mentre regoli dimensione, grassetto, colori, contorno, sfondo e distanza dal bordo; chiudi con «Fine» e guarda il risultato sul video. Le modifiche valgono per tutti i video (sono le stesse di *Riproduzione › Lingue › Stile dei sottotitoli*).
- **Se non va:** nome del file/addon e lingua.

## 6. Picture in Picture (con AVPlayer)
1. Con un **MP4** in riproduzione tocca l'icona Picture‑in‑Picture in alto a destra (accanto a ⋯; compare toccando lo schermo), oppure, con il video in riproduzione, vai alla Home con *Altro › Impostazioni › Riproduzione › Sistema › Picture‑in‑Picture automatico* acceso (lo è già di default).
2. **Deve succedere:** il video diventa una finestrella che si può spostare; toccandola compaiono i comandi di iOS e col pulsante per tornare all'app (quadratino con freccia) si ritorna in Aether, con il video che riprende nel player.
3. Ripeti con un **MKV** dopo aver attivato la conversione (prova 7). In **LiveContainer** il PiP può non partire: in quel caso compare per qualche secondo un messaggio in alto (es. «Il sistema non permette il Picture in Picture… In LiveContainer può non funzionare») e l'icona è attenuata.
- **Se non va:** installazione diretta o LiveContainer; il messaggio; il registro (le righe «player:» che contengono «Picture in Picture», più «App in background: PiP attivo…»).

## 7. MKV convertiti al volo per AVPlayer — **la novità più grande**
1. *Impostazioni › Riproduzione › Motore*: scegli **Player: AVPlayer (Apple)**, oppure lascia **Automatico** e accendi **Converti i file MKV per AVPlayer**.
2. Apri una sorgente **MKV** (video H.264 o HEVC, audio AAC/AC‑3/E‑AC‑3) e tocca Guarda.
   - **Deve succedere:** per qualche secondo «Preparo il file MKV per AVPlayer…», poi parte. Il foglio **Informazioni sulla sorgente** (menu ⋯ in alto) mostra la sezione **«Conversione al volo»** («MKV → HLS (copia, senza ricodifica)», l'audio che passa).
   - **Controlla:** il video è fluido; **l'audio è sincronizzato** col labiale (è il punto più delicato: se è in ritardo dimmi di quanto); **salta in avanti/indietro** (tocca la barra a metà e a fine) senza bloccarsi; **PiP** funziona (prova 6).
3. **Più tracce audio:** apri il pannello **Audio**: elenco «Italiano · AC‑3 5.1», «Inglese · AAC stereo»… Scegline un'altra: la riproduzione si ferma per qualche secondo («Preparo il file MKV per AVPlayer…»; «Cambio traccia audio…» può restare visibile solo un attimo) e **riparte dallo stesso punto** («Riprendo da …») con l'altra lingua. Se sei nei primi 5 secondi riparte dal punto di ripresa salvato o dall'inizio: prova dopo qualche secondo di video.
4. **File non convertibile:** prova un MKV con **solo audio DTS/TrueHD** o video VP9/AV1.
   - Con *Automatico* il file parte con **MPV**; in alto compare per qualche secondo il motivo («… Uso MPV.»). Controlla in ⋯ › Informazioni sulla sorgente che «Motore» dica MPV e che la sezione «Conversione al volo» non ci sia.
   - Con *Player: AVPlayer (Apple)* appare «Impossibile riprodurre» con la frase «Formato non supportato dal motore di riproduzione…» e, sotto, il motivo preciso (es. «L'audio è DTS e non può essere passato così com'è…») con il suggerimento di scegliere «Automatico» o «MPV».
5. **Dolby Vision:** un MKV con **profilo 7** (Blu‑ray) deve partire come HDR10 (nel foglio Informazioni, sezione «Conversione al volo», c'è la nota «Dolby Vision profilo 7: passa come HDR10…»). Il **profilo 5** non viene convertito: con *Automatico* il file parte con MPV, con *Player: AVPlayer (Apple)* appare «Impossibile riprodurre».
- **Se non va:** mandami il registro, il foglio Informazioni (screenshot) e, se riesci, `ffprobe` del file (codec video/audio); dimmi se l'audio è sfasato e di quanto.

## 8. AirPlay
- **MP4 / HLS con AVPlayer:** tocca il simbolo AirPlay in alto e scegli il televisore: il video deve andare sul televisore.
- **MKV convertito (prova 7):** prima accendi *Account e dati › Privacy › Consenti rete locale* (è spento di default) e collega il telefono al Wi‑Fi del televisore. Poi apri il selettore AirPlay: Aether passa il file al **ponte sul Wi‑Fi** (messaggio «Preparo il video per AirPlay…») e riprende dallo stesso punto. La prima volta iOS può chiedere il permesso **«Rete locale»** (se non l'hai già dato scansionando i dispositivi Cast): consenti. Se invece vedi «Per mandare questo MKV in AirPlay servono il Wi‑Fi e il permesso «Rete locale»», manca uno dei due. Scegli il televisore: **deve vedersi il video** (in basso compare la pillola «AirPlay · tramite Aether»). Serve un televisore con AirPlay 2 (per esempio molti Samsung e LG recenti): se non funziona scrivimi modello e anno.
- **Con MPV** (MKV in modalità Automatico predefinito): AirPlay manda **solo l'audio**. Aether lo dice una volta con un avviso «AirPlay: sul televisore va solo l'audio» (pulsanti «Trasmetti con Cast / DLNA» e «Va bene così»); sotto la barra di avanzamento resta la pillola «Solo audio · nome del dispositivo». Aprendo il selettore AirPlay compare anche «AirPlay con questo file: solo audio.»
- **Con un link TorBox non convertito (MP4/MOV/HLS, contiene la chiave):** AirPlay **non** porta il video (va solo l'audio); per qualche secondo compare l'avviso «AirPlay: questo link contiene la tua chiave TorBox…» e sotto la barra la pillola «Solo audio · nome». Se attivi *Impostazioni › Avanzate › Invia il link diretto al televisore* (prima di aprire il video) il video passa, con la chiave. Un **MKV** TorBox convertito (prova 7) invece passa dal ponte: il video si vede senza dare la chiave al televisore.
- **Se non va:** modello e anno del televisore, messaggio mostrato, se il permesso «Rete locale» è acceso in *Impostazioni di iOS › Aether*.

## 9. Google Cast / DLNA e il ponte
Prerequisiti: televisore acceso, stesso Wi‑Fi del telefono, nessuna VPN, *Account e dati › Privacy › Consenti rete locale* **acceso** (è spento di default), permesso «Rete locale» concesso a Aether in iOS.
1. *Altro › Casting*: attendi la scansione; il tuo televisore (Xiaomi Android TV = «Google Cast») deve comparire.
2. **MP4 con link pubblico** → tocca il pulsante «Trasmetti su Google Cast o DLNA» (icona televisore) in alto nel player e scegli il televisore: con un MP4 https normale parte direttamente, senza ponte. Se il file è HTTP, HEVC o hai un sottotitolo di Aether acceso compare prima un avviso «Trasmettere a …?»: tocca «Invia comunque».
3. **Link TorBox:** dopo aver scelto il televisore compare una conferma «Trasmettere a «nome»?» con il testo «Aether farà da ponte…»: tocca **Trasmetti**. La trasmissione passa dal **ponte** e nel player compare «Ponte attivo · il televisore non vede la tua chiave». Tieni il telefono acceso con Aether aperto. In *Impostazioni › Casting › Ponte sul telefono* lo stato dice «Pronto (indirizzo)».
4. **MKV su Google Cast:** con *Impostazioni › Casting › File MKV › Converti gli MKV per Google Cast* (acceso per default) e il ponte disponibile, dopo aver scelto il televisore la conferma «Trasmettere a …?» contiene la nota che il file viene convertito in HLS: tocca «Trasmetti»; deve partire dopo qualche secondo sul televisore. Se l'audio è solo DTS/TrueHD (o il video non è copiabile) Aether invia il file com'è: per un istante compare «Conversione non possibile: … Invio il file così com'è.» (può restare coperto dalla schermata «Riproduzione su …»), poi il televisore riceve l'MKV senza conversione.
5. **Telecomando sul telefono:** pausa/play, avanti/indietro; chiudi con **Torna a guardare sul telefono**: il video riprende sul telefono dallo stesso punto (se è acceso *Casting › Riproduzione remota › Riprendi sul telefono quando mi disconnetto*).
6. **Interruttore del link diretto:** *Avanzate › Invia il link diretto al televisore* resta **spento** per default; accendendolo compare un avviso e il televisore riceve la chiave. Dopo un ripristino da backup **con le impostazioni incluse** («Ripristina anche le impostazioni» acceso) deve tornare spento, anche se il backup lo aveva acceso.
7. **Casi sbagliati:** spegni il Wi‑Fi, oppure spegni *Consenti rete locale* nell'app, e riprova con un link TorBox: deve comparire «Serve il ponte sul telefono…» con il motivo e nessuna trasmissione. Togliendo il permesso «Rete locale» in *Impostazioni di iOS › Aether* la scansione non trova televisori e, se un televisore non riesce a collegarsi al telefono, il messaggio («Il televisore non è riuscito a collegarsi al telefono…») compare solo dopo qualche decina di secondi: scrivimi cosa vedi e dopo quanto.
- **Se non va:** il testo esatto dell'errore, il modello del televisore, e dopo quanto tempo. *Impostazioni › Casting › Dispositivi, sessioni e diagnostica* mostra i dispositivi trovati, la sessione attiva e l'ultimo errore; il registro (voci «ponte», «remux», «player») è in *Impostazioni › Avanzate › Diagnostica › Mostra il registro*. Se il televisore dice che non riesce a collegarsi al telefono, controlla l'isolamento dei client sul router (spesso nelle reti «ospiti»).

## 10. TorBox
*Impostazioni › Servizi › TorBox*: incolla la chiave nel campo «Chiave API di TorBox» → **Salva** (la verifica parte da sola: devono comparire «Chiave salvata nel Portachiavi» e «Connesso a TorBox · piano …»; con **Verifica connessione** la ripeti). Se TorBox rifiuta la chiave il campo ricompare con «… La chiave non è stata salvata.»
- Apri un titolo e tocca **Guarda**: nell'elenco «Scegli la sorgente» le righe torrent mostrano prima **Verifica…** e poi **In cache** (verde) o **Non in cache** (arancione); i torrent in cache passano davanti agli altri torrent. Serve la chiave TorBox salvata: senza, la riga dice «Per riprodurlo configura TorBox in Impostazioni › Servizi.»
- Una sorgente **in cache** parte (MPV per gli MKV, oppure convertita se lo hai scelto). Una **non in cache** chiede conferma prima di aggiungere il download.
- **Se non va:** messaggio dell'errore (chiave rifiutata, link scaduto…).

## 11. Navigazione di base e ricerca
- **Home:** sezioni (In evidenza, Continua a guardare, cataloghi…); *Impostazioni › Aspetto › Personalizza la Home* per ordine, stile delle schede, schermo intero, saluto.
- **Scopri:** categorie e filtri; **Cerca:** digita un titolo, filtri dinamici per tipo/genere.
- **Libreria** (segmenti): Continua · Watchlist · Preferiti · Cronologia · Download. Dalla scheda di un titolo il **segnalibro** (accanto a Guarda) lo mette in *Watchlist*, il **cuore** (in alto a destra) in *Preferiti*: controlla che compaia nel segmento giusto.
- **Serie:** nella sezione «Episodi» il menu delle stagioni compare in alto a destra solo se ci sono più stagioni («Stagione 1», «Stagione 2», «Speciali»…). Sopra l'elenco c'è il pulsante **Segna stagione 1 come vista** (diventa «… come non vista» quando sono già tutti visti). Ogni episodio ha la barra di avanzamento sulla miniatura se lo hai guardato a metà, e la spunta verde se è visto. Tieni premuto un episodio › **Segna come visto** (poi «Segna come non visto»); lo stesso comando c'è tenendo premuta una scheda in *Continua*. Il tasto principale diventa **Riprendi S01E03** (solo se hai interrotto l'episodio dopo almeno 10 secondi; altrimenti dice **Guarda S01E04** per il prossimo da vedere).
- **Prossimo episodio:** su una serie, negli ultimi 45 secondi dell'episodio compare in basso a destra la scheda «Prossimo episodio» con il titolo (es. «S01E04 · …») e **Riproduci ora**. Se «Riproduci automaticamente il prossimo episodio» è acceso (lo è di default), negli ultimi 8 secondi circa compare anche «Parte tra N s» con **Annulla**, e a zero parte da solo. (Il conto si regola in *Riproduzione › Episodi*.)
- **Salta intro / riassunto** (IntroDB, solo serie con dati): compare il pulsante mentre sei nell'intro.

## 12. Download
Tocca **Guarda**; nell'elenco «Scegli la sorgente», su una sorgente che è un file diretto su https (es. MP4) scorri la riga verso sinistra e tocca **Scarica** (oppure tienila premuta › «Scarica per guardarlo offline»): compare «Download avviato. Lo trovi in Libreria ▸ Download.» I torrent, i flussi HLS e i link http non cifrati vengono rifiutati con un messaggio che ne spiega il motivo.
In *Libreria › Download* controlla l'avanzamento (percentuale e barra; prova anche pausa e ripresa), la riproduzione offline con l'icona ▶ a destra della riga (anche in modalità aereo) e l'eliminazione scorrendo la riga verso sinistra › **Elimina**. *Impostazioni › Archiviazione* mostra lo spazio usato e permette di svuotare le cache.

## 13. Dati, privacy e impostazioni
- *Account e dati* (sezione «Privacy»): gli interruttori «Registra cronologia e punti di ripresa» (acceso di default), «Consenti rete locale (addon, sorgenti, Cast)» (**spento** di default) e «Conserva il log diagnostico (solo su questo dispositivo)» (acceso di default); **Elimina tutti i dati locali…** (chiede conferma con «Eliminare tutti i dati locali?» › «Elimina tutto»; prova solo su dati che puoi perdere).
- *Aspetto*: tema, dimensione e densità delle schede, *Animazioni*, *Riduci gli effetti visivi*.
- **Easter egg:** nella pagina *Altro › Informazioni e licenze* tocca il logo in cima 7 volte di fila, senza fermarti più di un secondo e mezzo tra un tocco e l'altro (al 3º e al 5º compare una frase). Al 7º il logo gira e piovono popcorn con un messaggio (con *Animazioni* spente o «Riduci movimento» di iOS acceso compare solo il messaggio). La prima volta sblocca il tema «Popcorn» in *Impostazioni › Aspetto › Stile e grafica*.
- **Accessibilità:** con VoiceOver acceso naviga la Home, una scheda e il player: i pulsanti devono avere un nome («Sottotitoli», «Audio», «Chiudi il pannello»…). Prova anche il testo grande: *Impostazioni di iOS › Accessibilità › Schermo e dimensione del testo › Testo più grande* (oppure lo slider in *Schermo e luminosità › Dimensioni del testo*): niente deve uscire dallo schermo.

## 14. Cose che dovrebbero andare in modo diverso da prima
- In AirPlay un link TorBox **non convertito** non dà più il video al televisore (prima sì); un MKV TorBox convertito passa invece dal ponte, senza dare la chiave.
- L'ordine delle sorgenti **non è più quello «migliori per prime»** ma «Per addon» (per tornare al vecchio: Riproduzione › Sorgenti).
- Gli MKV in *Automatico* vanno ancora a **MPV** finché non accendi «Converti i file MKV per AVPlayer».
- Se un MKV non si può convertire, il motivo ora si vede (in alto per qualche secondo con *Automatico*; nel pannello «Impossibile riprodurre» con *Player: AVPlayer*).

---

### Cosa mi serve se qualcosa non va
1. Quale prova (numero) e cosa ti aspettavi.
2. Cosa è successo davvero, con **testo esatto** dei messaggi o uno screenshot.
3. Modello di iPhone, versione di iOS, **installazione diretta o LiveContainer**, e per Cast/AirPlay il modello e l'anno del televisore.
4. Il **registro** (*Avanzate › Diagnostica › Mostra il registro*), copiato **prima di chiudere l'app**.
