# Cosa provare in Aether 1.2 Beta 1 (e come)

Lista pensata per chi prova l'IPA su un iPhone vero (anche in LiveContainer). Per ogni prova: **Come** si fa, **Deve succedere** cosa vedere, **Se non va** cosa mi serve sapere.
Le prove sono ordinate dalle più importanti (cose nuove o mai viste su un telefono) alle più normali. Segna accanto a ciascuna ✅ / ❌ / ➖ (non applicabile).

**Prima di cominciare**
- Installa l'IPA firmato da te (AltStore, Sideloadly). Se usi **LiveContainer** annotalo: Picture in Picture, Cast e il permesso «Rete locale» possono comportarsi in modo diverso da un'installazione diretta. Per le prove 7, 8 e 9 conviene un'installazione diretta.
- Attiva il registro: *Altro › Impostazioni › Avanzate › Diagnostica › Registro dettagliato*. Quando qualcosa non va, torna lì, tocca **Mostra il registro** e mandami il testo (non contiene chiavi né indirizzi con chiavi).
- Ti servono: almeno un addon di cataloghi (Cinemeta) e uno di sorgenti; meglio due addon di sorgenti (prova 4); una chiave TMDB (gratuita su themoviedb.org › Impostazioni › API) e, se ce l'hai, TorBox; per Cast/AirPlay, un televisore sulla stessa rete Wi‑Fi.

---

## 1. Backup e ripristino (il difetto che hai trovato) — **PROVA SUBITO**
1. *Altro › Impostazioni › Account e dati › Backup e ripristino.* (se vuoi, accendi **Includi gli indirizzi degli addon**: senza, gli addon vanno reinstallati a mano). Tocca **Crea backup…**, poi **Condividi Aether-Backup-….json** e salva il file in *File › Sul mio iPhone* (o iCloud Drive).
2. Aggiungi un titolo ai Preferiti o guarda 20 secondi di un video, così i dati cambiano.
3. Tocca **Ripristina da file…** e scegli il file salvato.
   - **Deve succedere:** il file si apre (nessun file è «grigio»: ora si può scegliere qualunque file), e **nella pagina** compare la sezione **«Backup scelto»** con il nome del file e un riepilogo («N titoli salvati · N punti di visione · N addon · impostazioni incluse», data e versione di Aether). Se il file non è un backup, un messaggio lo dice subito con il nome del file.
   - Tocca **Unisci ai dati attuali** → «Ripristino completato: …». Prova anche **Sostituisci tutto…** (chiede conferma) e **Annulla**.
   - Con l'interruttore **Ripristina anche le impostazioni** spento le impostazioni non cambiano.
4. Prova anche con un file che non è un backup (un'immagine o un altro .json): deve dire «Il file non è un backup di Aether» o «Non riesco ad aprire il file: …» con il motivo.
- **Se non va:** dimmi dove l'avevi salvato (File › Sul mio iPhone, iCloud Drive, cartella di un'altra app), se il file appare grigio nel selettore, e il messaggio che compare. Se il messaggio è «Non riesco ad aprire il file: …», copiami il resto della frase.

## 2. La scheda del titolo con i dati TMDB
**Senza chiave:** apri un film. **Deve succedere:** in fondo una riga «Aggiungi la tua chiave TMDB in Impostazioni › Servizi…».
**Con chiave:** *Impostazioni › Servizi › TMDB*: incolla la chiave → **Salva e verifica** (deve comparire «Il servizio accetta la chiave.» e «Chiave salvata nel Portachiavi»). Apri un film popolare (es. «Dune»).
- **Deve succedere** (a pezzi, scorrendo la scheda): **Cast** con foto rotonde e nome del personaggio; **Trailer** (elenco, ognuno si apre in YouTube) e il pulsante «film» accanto a Play che con più trailer apre un menu; **Produzione** (loghi su tessera chiara); **Budget / Incassi** (solo per i film); **Dettagli** (Stato, Info rilascio, Durata, Certificazione, Paesi, Lingua originale); **Titoli simili** (toccane uno: si apre la sua scheda; se non esiste negli addon dice perché); in fondo «**Offerto da TMDB**» e l'avviso richiesto da TMDB.
- Apri una **serie**: niente Budget/Incassi; compaiono «Creato da», le stagioni («8 stagioni · 73 episodi») e i canali tra le produzioni.
- Disattiva il Wi‑Fi e riapri un titolo già visto: le sezioni TMDB compaiono dalla cache (24 ore) o mancano senza errori.
- **Se non va:** dimmi quale sezione manca e il titolo; per «simili» il messaggio che compare.

## 3. Ordine delle sorgenti «Per addon» e pillola del formato
1. Con **due addon di sorgenti** (A sopra, B sotto): *Altro › Addon*, tocca **Modifica** e trascina per cambiare l'ordine.
2. Apri un titolo che entrambi hanno e tocca **Guarda**.
   - **Deve succedere:** nell'elenco le sorgenti di **A vengono tutte prima** di quelle di B (dentro ogni addon: lingua, qualità, codec). I chip degli addon in alto filtrano.
3. *Impostazioni › Riproduzione › Sorgenti › Ordine delle sorgenti* → **Le migliori per prime**: ora l'elenco è mescolato per qualità. Rimetti «Per addon».
4. Attiva **Scegli automaticamente la sorgente migliore** e riapri il titolo: deve partire una sorgente del **primo addon** (se ha qualcosa di riproducibile).
5. **Pillola del formato:** su ogni sorgente compare un contorno con **MKV / AVI / MP4 / MOV / M4V / TS / WEBM** (o **HLS** per le playlist); su un risultato senza estensione riconoscibile non c'è. VoiceOver legge «Formato MKV».
- **Se non va:** mandami nome dei due addon, ordine e cosa vedi.

## 4. Il player: pannelli laterali e pulsanti
Apri un MP4 (o qualunque sorgente) e fai partire il video.
- **Pulsanti sotto la barra di avanzamento:** Sottotitoli · Audio · Sorgenti (se ce ne sono altre) · Velocità · Riempi · Episodi (solo serie). Su schermo stretto mostrano solo le icone.
- **Sottotitoli:** tocca il pulsante. **Deve succedere:** a destra, circa 40% dello schermo, **il video resta visibile ma attenuato** e la tua scelta si applica subito. Due colonne: **lingue** a sinistra («Tutte» e una riga per lingua con il numero), **elenco** a destra («Disattivati», tracce incorporate, poi i sottotitoli degli addon). In basso: **− / + ritardo** (mezzo secondo per tocco, «Azzera»), **Importa** (da file sottotitoli, anche dal menu ⋯ › Importa sottotitoli…) e **Stile**.
- **Audio:** elenco delle tracce con la spunta su quella attiva. **Sorgenti:** chip per addon in alto, la sorgente in riproduzione, poi le alternative; toccarne una cambia sorgente e riprende dallo stesso punto.
- Per chiudere un pannello: tocca la parte scura a sinistra, la **✕**, o il gesto VoiceOver «Scorri con due dita a Z».
- **Velocità** (pulsante con menu delle velocità), **Riempi / Adatta** (riempie lo schermo o lo adatta), **Blocca i controlli** (lucchetto in basso; si sblocca col pulsante «Sblocca»), **Timer di spegnimento** (menu ⋯ › Timer di spegnimento), gesti (luminosità a sinistra, volume a destra, doppio tocco per saltare), tenere premuto per accelerare (velocità scelta in *Riproduzione › Controlli*).
- **Se non va:** dimmi quale pannello, orientamento (verticale/orizzontale) e modello di iPhone; uno screenshot aiuta molto.

## 5. Sottotitoli
- **Da addon:** con un addon di sottotitoli (es. OpenSubtitles) apri il pannello: i sottotitoli compaiono raggruppati per lingua, quella preferita per prima. Sceglierne uno li mostra in 1–2 secondi.
- **Da file:** pannello › **Importa** › un .srt: deve comparire nell'elenco in «Da file» e mostrarsi.
- **Ritardo:** con − / + il testo si sposta; «Azzera» lo riporta a 0.
- **Stile:** pannello › **Stile** (dimensione, colore, contorno, posizione); le modifiche si vedono dal vivo.
- **Se non va:** nome del file/addon e lingua.

## 6. Picture in Picture (con AVPlayer)
1. Con un **MP4** in riproduzione tocca il pulsante Picture‑in‑Picture del player, oppure vai alla Home con *Impostazioni › Riproduzione › Sistema › Picture‑in‑Picture automatico* acceso.
2. **Deve succedere:** il video diventa una finestrella; si può spostare; toccandola si torna in Aether.
3. Ripeti con un **MKV** dopo aver attivato la conversione (prova 7). In **LiveContainer** il PiP può non partire: in quel caso il pulsante lo dice.
- **Se non va:** installazione diretta o LiveContainer; il messaggio del pulsante; il registro (voce «PiP»).

## 7. MKV convertiti al volo per AVPlayer — **la novità più grande**
1. *Impostazioni › Riproduzione › Motore*: scegli **Player: AVPlayer (Apple)**, oppure lascia **Automatico** e accendi **Converti i file MKV per AVPlayer**.
2. Apri una sorgente **MKV** (video H.264 o HEVC, audio AAC/AC‑3/E‑AC‑3) e tocca Guarda.
   - **Deve succedere:** per qualche secondo «Preparo il file MKV per AVPlayer…», poi parte. Il foglio **Informazioni sulla sorgente** (menu ⋯ in alto) mostra la sezione **«Conversione al volo»** («MKV → HLS (copia, senza ricodifica)», l'audio che passa).
   - **Controlla:** il video è fluido; **l'audio è sincronizzato** col labiale (è il punto più delicato: se è in ritardo dimmi di quanto); **salta in avanti/indietro** (tocca la barra a metà e a fine) senza bloccarsi; **PiP** funziona (prova 6).
3. **Più tracce audio:** apri il pannello **Audio**: elenco «Italiano · AC‑3 5.1», «Inglese · AAC stereo»… Scegline un'altra: mostra «Cambio traccia audio…», la riproduzione **riparte dallo stesso punto** con l'altra lingua.
4. **File non convertibile:** prova un MKV con **solo audio DTS/TrueHD** o video VP9/AV1. Con *Automatico* deve comparire un messaggio e il file parte con **MPV**; con *Player AVPlayer* appare «Impossibile riprodurre» con il motivo e il suggerimento di scegliere Automatico/MPV.
5. Un MKV con **Dolby Vision profilo 7** (Blu‑ray) deve partire come HDR10 (nel foglio Informazioni c'è la nota); il profilo 5 viene rifiutato.
- **Se non va:** mandami il registro, il foglio Informazioni (screenshot) e, se riesci, `ffprobe` del file (codec video/audio); dimmi se l'audio è sfasato e di quanto.

## 8. AirPlay
- **MP4 / HLS con AVPlayer:** tocca il simbolo AirPlay in alto e scegli il televisore: il video deve andare sul televisore.
- **MKV convertito (prova 7)**: apri il selettore AirPlay; Aether passa il file al **ponte sul Wi‑Fi** (messaggio «Preparo il video per AirPlay…», la prima volta iOS chiede **«Rete locale»**: consenti) e riprende dallo stesso punto. Scegli il televisore: **deve vedersi il video** (televisori con AirPlay 2: Samsung/LG dal 2018/19).
- **Con MPV** (MKV in modalità Automatico predefinito): AirPlay manda **solo l'audio** e Aether lo dice una volta («Solo audio · nome»).
- **Con un link TorBox (contiene la chiave):** AirPlay **non** porta il video (va solo l'audio) e compare l'avviso; se attivi *Avanzate › Invia il link diretto al televisore* il video passa (con la chiave).
- **Se non va:** modello e anno del televisore, messaggio mostrato, se il permesso «Rete locale» è acceso in *Impostazioni di iOS › Aether*.

## 9. Google Cast / DLNA e il ponte
Prerequisiti: televisore acceso, stesso Wi‑Fi del telefono, nessuna VPN, *Impostazioni › Account e dati › Privacy › Consenti rete locale* acceso, permesso «Rete locale» concesso a Aether in iOS.
1. *Altro › Casting*: attendi la scansione; il tuo televisore (Xiaomi Android TV = «Google Cast») deve comparire.
2. **MP4 con link pubblico** → tocca il pulsante «Trasmetti su Google Cast o DLNA» (icona televisore) in alto nel player e scegli il televisore: parte direttamente, senza ponte.
3. **Link TorBox:** la trasmissione passa dal **ponte** («Aether farà da ponte…», nel player compare «Ponte attivo · il televisore non vede la tua chiave»). Tieni il telefono acceso con Aether aperto. In *Impostazioni › Casting › Ponte sul telefono* lo stato dice «Pronto (indirizzo)».
4. **MKV su Google Cast:** con *Casting › File MKV › Converti gli MKV per Google Cast* (acceso) la nota dice che il file viene convertito in HLS; deve partire dopo qualche secondo sul televisore. Se l'audio è solo DTS, Aether lo dice e invia il file com'è.
5. **Telecomando sul telefono:** pausa/play, avanti/indietro; chiudi con **Torna a guardare sul telefono**: il video riprende sul telefono dallo stesso punto (se è acceso *Casting › Riproduzione remota › Riprendi sul telefono quando mi disconnetto*).
6. **Interruttore del link diretto:** *Avanzate › Invia il link diretto al televisore* resta **spento** per default; accendendolo compare un avviso e il televisore riceve la chiave. Dopo un ripristino da backup deve tornare spento.
7. **Casi sbagliati:** spegni il Wi‑Fi o togli il permesso «Rete locale» e riprova: messaggio chiaro, nessuna trasmissione.
- **Se non va:** il testo esatto dell'errore, il modello del televisore, e dopo quanto tempo; *Casting › Dispositivi, sessioni e diagnostica* mostra lo stato e il registro. Se il televisore dice che non riesce a collegarsi al telefono, controlla l'isolamento dei client sul router (spesso nelle reti «ospiti»).

## 10. TorBox
*Impostazioni › Servizi › TorBox*: incolla la chiave → **Salva e verifica**.
- Apri un titolo: sulle sorgenti torrent compare il badge **In cache / Non in cache**.
- Una sorgente **in cache** parte (MPV per gli MKV, oppure convertita se lo hai scelto). Una **non in cache** chiede conferma prima di aggiungere il download.
- **Se non va:** messaggio dell'errore (chiave rifiutata, link scaduto…).

## 11. Navigazione di base e ricerca
- **Home:** sezioni (In evidenza, Continua a guardare, cataloghi…); *Impostazioni › Aspetto › Personalizza la Home* per ordine, stile delle schede, schermo intero, saluto.
- **Scopri:** categorie e filtri; **Cerca:** digita un titolo, filtri dinamici per tipo/genere.
- **Libreria** (segmenti): Continua · Watchlist · Preferiti · Cronologia · Download. Aggiungi un titolo con il segnalibro/cuore nella scheda e controlla che compaia; tieni premuto un episodio per «Segna come visto».
- **Serie:** menu delle stagioni, «Segna la stagione come vista», episodi con avanzamento; il tasto principale diventa «Riprendi S1·E3».
- **Prossimo episodio:** a fine episodio compare la scheda «Prossimo episodio» con il conto alla rovescia (annulla o «Riproduci ora»).
- **Salta intro / riassunto** (IntroDB, solo serie con dati): compare il pulsante mentre sei nell'intro.

## 12. Download
Su una sorgente scaricabile (MP4) usa «Scarica»; in *Libreria › Download* controlla avanzamento, riproduzione offline (modalità aereo) ed eliminazione. *Impostazioni › Archiviazione* mostra lo spazio usato e permette di svuotare le cache.

## 13. Dati, privacy e impostazioni
- *Account e dati*: interruttori «Registra cronologia», «Consenti rete locale», «Conserva il log diagnostico»; **Elimina tutti i dati locali…** (chiede conferma; prova solo su dati che puoi perdere).
- *Aspetto*: tema, dimensione e densità delle schede, *Animazioni*, *Riduci gli effetti visivi*; l'**easter egg** (tocca ripetutamente il logo nella pagina *Altro › Informazioni e licenze*).
- **Accessibilità:** con VoiceOver acceso naviga la Home, una scheda e il player: i pulsanti devono avere un nome («Sottotitoli», «Audio», «Chiudi il pannello»…). Prova anche «Testo più grande» in *iOS › Accessibilità › Dimensioni del testo*: niente deve uscire dallo schermo.

## 14. Cose che dovrebbero andare in modo diverso da prima
- In AirPlay un link TorBox **non** dà più il video al televisore (prima sì).
- L'ordine delle sorgenti **non è più quello «migliori per prime»** ma «Per addon» (per tornare al vecchio: Riproduzione › Sorgenti).
- Gli MKV in *Automatico* vanno ancora a **MPV** finché non accendi «Converti i file MKV per AVPlayer».

---

### Cosa mi serve se qualcosa non va
1. Quale prova (numero) e cosa ti aspettavi.
2. Cosa è successo davvero, con **testo esatto** dei messaggi o uno screenshot.
3. Modello di iPhone, versione di iOS, **installazione diretta o LiveContainer**, e per Cast/AirPlay il modello e l'anno del televisore.
4. Il **registro** (*Avanzate › Diagnostica › Mostra il registro*).
