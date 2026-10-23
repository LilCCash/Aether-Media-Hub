# Aether TV 1.0.0 Beta 1 (Android TV)

La versione per **Android TV** di Aether: un'app nativa (Kotlin, Jetpack Compose, Media3/ExoPlayer) pensata per il telecomando. Mostra e riproduce i contenuti dei **tuoi addon Stremio**. Aether non fornisce nessun contenuto: gli addon li scegli e li installi tu. È un progetto indipendente, senza legami con Stremio.

> **Versione:** 1.0.0 Beta 1 · pacchetto `app.aether.tv` · Android 7.0 (API 24) o successivo · licenza MIT
> **Pre-release.** L'app è compilata e testata in CI, ma **non è ancora stata provata a lungo su una TV vera**: aspettati qualche difetto.

## Come installarla
1. Scarica `Aether-TV-1.0.0-beta.1.apk` qui sotto.
2. Sulla TV abilita «Origini sconosciute» per l'app che userai (es. *Downloader*, un file manager) oppure installa con `adb install -r Aether-TV-1.0.0-beta.1.apk`.
3. Apri **Aether TV** dal menu delle app. Il file è firmato con la chiave di debug (non è un APK di store).

## Cosa sa fare

**Addon**
- Installazione da indirizzo con anteprima, avvisi (non verificato, p2p, adulti, rete locale) e controllo dei duplicati; link `stremio://` e `aether://`.
- **Aggiunta dal telefono:** apri la pagina sulla TV, inquadra il **codice QR** (o digita il link) e incolla l'addon dal telefono; dopo ogni installazione la pagina torna da sola al modulo, senza ricaricare.
- Abilita/disabilita, ordine di priorità, rinomina, cataloghi nascosti, aggiorna e rimuovi.
- Indirizzi degli addon e chiavi cifrati con il Keystore di Android.

**Home, Scopri e Cerca**
- Home con titolo in evidenza, righe dei cataloghi, «Continua a guardare» e «Prossimo episodio».
- Scopri per tipo, catalogo e genere, con caricamento progressivo.
- Ricerca su tutti i cataloghi, risultati man mano, ordine, **filtri per anno e genere**, ricerche recenti e ricerca nella libreria.

**Scheda del titolo**
- Sfondo, trama, generi, cast, regia, stagioni ed episodi con progressi, «visto/non visto» (titolo, episodio, stagione), watchlist e preferiti, trailer.
- Con la tua chiave **TMDB** (v3 o token v4): cast con foto, produzioni, budget e incassi, trailer e titoli simili. Con **TheTVDB** (chiave v4, PIN per gli abbonati): trame, locandine e immagini degli episodi. In Impostazioni il pulsante «Verifica» dice perché una chiave viene rifiutata.

**Sorgenti**
- Analisi dei nomi (qualità, codec, HDR, audio, lingua, dimensione, formato), ordine «per addon» o «migliori», scelta automatica con continuità della release.
- **TorBox:** controllo della cache, da torrent a link, download con conferma, scelta del file.

**Player (Media3 / ExoPlayer)**
- Link diretti, HLS, DASH, MKV, WebM, TS, MP4; telecomando completo (OK = play/pausa, sinistra/destra = salti con accelerazione, Indietro chiude pannelli e controlli).
- Tracce audio e sottotitoli (anche quelli degli addon), stile dei sottotitoli, **ritardo** dei sottotitoli, **rimozione delle annotazioni per non udenti**, velocità, formato dello schermo.
- **Amplificazione audio** fino a +18 dB oltre il volume della TV, **timer di spegnimento**, ripresa del punto, episodio successivo automatico con conto alla rovescia, **Salta intro / riassunto** (IntroDB), errori spiegati con «altra sorgente».

**Libreria e dati**
- Continua a guardare, watchlist, preferiti, cronologia; **backup e ripristino** nello stesso formato di Aether per iPhone (si leggono anche i backup dell'iPhone).

**Interfaccia**
- Tema scuro cinematografico, focus sempre ben visibile, menu laterale che si espande, ritorno sul poster in cui eri, accento e dimensione delle locandine regolabili.
- Nome **Aether TV**, logo di Aether nelle Impostazioni e in Informazioni (premi OK sul logo più volte…).
- Rete più robusta: IPv4 per primo e DNS di riserva (Cloudflare/Google) quando il DNS del router non risolve un indirizzo.

## Cosa non c'è (e perché)
- **Theater Mode, Google Cast, AirPlay, DLNA, Picture in Picture, gesti, download offline:** pensati per il telefono o non applicabili a una TV.
- **MPV, remux e conversione:** non portati; **AVI, WMV e l'audio DTS non sono riproducibili** (servirebbe un decoder FFmpeg).
- **Personalizzazione avanzata della Home** (sezioni, saluto, temi), registro diagnostico, hash dei sottotitoli: non portati.
- Il ritardo dei sottotitoli può solo posticipare, non anticipare.
- Elenco completo: `android-tv/docs/PARITA.md`.

## Cosa è stato provato
- ✅ Test automatici del core (protocollo addon, ranking, libreria, backup, TorBox, TMDB/TheTVDB con server finti), lint bloccante, test dell'interfaccia con telecomando simulato, controllo del pacchetto TV (leanback, banner, touchscreen non richiesto).
- ⚠️ **Non provato su una TV o un emulatore:** aspetto e fluidità, riproduzione e decodifica reali, TorBox/TMDB/TheTVDB contro i servizi veri, amplificazione audio, deep link, Keystore sul dispositivo.
- Se qualcosa non funziona, apri un'issue con il testo esatto dell'errore: i messaggi indicano la causa.
