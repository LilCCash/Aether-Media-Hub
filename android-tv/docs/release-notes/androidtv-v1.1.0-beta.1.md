# Aether TV 1.1 Beta 1 (Android TV)

Seconda versione di **Aether TV**, l'app nativa per Android TV (Kotlin, Jetpack Compose, Media3/ExoPlayer) che mostra e riproduce i contenuti dei **tuoi addon Stremio**. Aether non fornisce nessun contenuto: gli addon li scegli e li installi tu. Progetto indipendente, senza legami con Stremio.

> **Versione:** 1.1.0 Beta 1 (build 2) · pacchetto `app.aether.tv` · Android 7.0 (API 24) o successivo · licenza MIT
> **Pre-release.** Compilata e testata in CI, **non ancora provata a lungo su una TV vera**.

## Come installarla
1. Scarica `Aether-TV-1.1.0-beta.1.apk` qui sotto.
2. Sulla TV abilita «Origini sconosciute» per l'app che usi per aprire il file (es. *Downloader*) oppure `adb install -r Aether-TV-1.1.0-beta.1.apk`. Si installa sopra la 1.0 senza perdere addon e dati.
3. Il file è firmato con la chiave di debug (non è un APK da store).

## Novità della 1.1

**Correzioni importanti**
- **Addon / Cinemeta: «Impossibile raggiungere» / `NetworkOnMainThreadException`.** Le risposte di rete venivano lette sul thread principale di Android, che lo vieta: ora il download gira su un thread separato. Questo risolve l'installazione degli addon e il caricamento dei cataloghi.
- **Rete più robusta:** IPv4 per primo e DNS di riserva (Cloudflare/Google) quando il DNS del router non risolve un indirizzo; i messaggi d'errore ora dicono la causa vera.
- **TMDB e TheTVDB riscritti:** ora funzionano sia con la chiave v3 sia con il token v4 («eyJ…»), cercano per codice IMDb, in italiano, e in Impostazioni ci sono i pulsanti **Verifica** che spiegano perché una chiave viene rifiutata.
- **Informazioni su Aether:** ora scorre con il telecomando.

**Aggiungere addon e chiavi dal telefono**
- Pagina temporanea sulla stessa Wi-Fi con **codice QR** (oltre al link): inquadri, incolli l'addon e la pagina torna da sola al modulo dopo ogni installazione.
- Dalla stessa pagina puoi inserire anche le **chiavi TMDB, TheTVDB (e PIN) e TorBox**, senza digitarle con il telecomando.

**Player**
- **Controlli più piccoli e proporzionati;** la riga dei pulsanti scorre e mostra intero il pulsante evidenziato.
- **Sottotitoli riorganizzati come su iPhone:** prima la sorgente («Nel file», poi un'entrata per ogni addon), poi le lingue, con la tua lingua in cima; i doppioni sono numerati.
- **Sincronia dei sottotitoli con slider** (da −15 a +15 s, passi di 0,1 s): si possono **ritardare e anticipare**. Per i sottotitoli degli addon (scaricati e letti dall'app, anche in codifica Windows-1252) funzionano entrambi; per quelli dentro il file si può solo ritardare.
- **Amplificazione audio riscritta** (fino a +18 dB oltre il volume della TV) con un amplificatore dentro il player e un limitatore contro la distorsione. Con un gain impostato il player non manda l'audio Dolby/DTS in passthrough all'impianto (non sarebbe amplificabile).
- **Timer di spegnimento** (in player e come predefinito), **rimozione delle annotazioni per non udenti** nei sottotitoli.

**Scheda del titolo**
- Con la chiave TMDB: cast con foto, produzioni, budget e incassi, trailer e **titoli simili** apribili. Con TheTVDB: trame, locandine e immagini degli episodi.

**Cerca**
- **Filtri per decennio e genere** sui risultati.

**Consigliami (nuovo)**
- Voce nella barra laterale: scegli Film o Serie e il genere, ti vengono mostrati 20 titoli casuali; selezioni quelli che ti piacciono e ottieni **5 consigli** in base a generi, voti e anni (e, con la chiave TMDB, ai suoi titoli simili). «Altri titoli» ne mostra altri 20.

**Aspetto**
- Nome **Aether TV**, logo di Aether in icona, banner, Impostazioni e Informazioni (premi OK sul logo più volte…).
- **5 sfondi** (Notte, Aurora animata, Cinema, Oceano, Braci) e **3 stili di angoli** (squadrati, morbidi, molto tondi).

## Tutto il resto (dalla 1.0)
Installazione e gestione degli addon, Home con titolo in evidenza e «Continua a guardare», Scopri, scheda con stagioni ed episodi, sorgenti ordinate con TorBox, player con tracce audio, sottotitoli degli addon, velocità, ripresa, episodio successivo, Salta intro, libreria, preferiti, cronologia, backup compatibile con Aether per iPhone. Dettaglio in `android-tv/docs/PARITA.md`.

## Cosa non c'è
- Theater Mode, Google Cast, AirPlay, DLNA, Picture in Picture, download offline: pensati per il telefono.
- **AVI, WMV e audio DTS non sono riproducibili** (servirebbe un decoder FFmpeg); nessun remux.
- Personalizzazione avanzata della Home (sezioni, saluto, temi), registro diagnostico.

## Cosa è stato provato
- ✅ Test automatici (core, TMDB/TheTVDB con server finti, parser dei sottotitoli e anticipo/ritardo, consigli), lint bloccante, test dell'interfaccia con telecomando simulato, controllo del pacchetto TV.
- ⚠️ **Non provato su una TV:** correzione di rete, pagina del telefono e QR, aspetto e scorrimento dei controlli, sottotitoli e slider, **amplificazione audio**, Consigliami, sfondi, TorBox/TMDB/TheTVDB contro i servizi veri.
- Se qualcosa non funziona, apri un'issue con il testo esatto dell'errore.
