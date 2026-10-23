# Aether TV 1.2 Beta 1 (Android TV)

Terza versione di **Aether TV**, l'app nativa per Android TV (Kotlin, Jetpack Compose, Media3/ExoPlayer) che mostra e riproduce i contenuti dei **tuoi addon Stremio**. Aether non fornisce nessun contenuto: gli addon li scegli e li installi tu. Progetto indipendente, senza legami con Stremio.

> **Versione:** 1.2.0 Beta 1 (build 3) · pacchetto `app.aether.tv` · Android 7.0 (API 24) o successivo · licenza MIT
> **Pre-release.** Compilata e testata in CI, **non ancora provata a lungo su una TV vera**.

## Come installarla
1. Scarica `Aether-TV-1.2.0-beta.1.apk` qui sotto.
2. Sulla TV abilita «Origini sconosciute» per l'app con cui apri il file (es. *Downloader*) oppure `adb install -r Aether-TV-1.2.0-beta.1.apk`. Si installa sopra la versione precedente senza perdere addon e dati.
3. Il file è firmato con la chiave di debug (non è un APK da store).

## Novità della 1.2

**Scheda del titolo**
- Ogni voce dei dettagli (regia, paese, produzione, premi…) e la **trama** sono ora selezionabili: premi OK per leggerle intere in un riquadro.
- **Clic su un attore** del cast: si apre la sua filmografia (da TMDB), con per ogni titolo il **nome del film** e sotto il **ruolo interpretato** («nel ruolo di…»).
- Nuova impostazione **«Lingua di trama e dettagli»** (italiano, inglese, francese, spagnolo, tedesco, portoghese): con la chiave TMDB la trama e i generi arrivano nella lingua scelta, anche se l'addon li fornisce in inglese.

**Scopri e Cerca**
- Filtri **a tendina** (Tipo, Catalogo, Genere, **Anno/decennio**) al posto della lunga fila di pulsanti: niente più scorrimenti infiniti né salti del focus.
- Locandine tutte della **stessa altezza** (due righe di titolo + una di dettaglio): non più titoli o locandine tagliati, e la griglia non «sfarfalla».

**Player**
- **Apre subito:** scegliendo una sorgente il player si apre senza aspettare, e TorBox viene contattato *con il player già aperto*. Nell'attesa compare il **logo trasparente del film** (da fanart.tv, in lingua se disponibile) con lo stato dell'operazione; Indietro annulla. Si può spegnere in Impostazioni ▸ Riproduzione («Logo del film mentre carico»).
- **Ombre dei pulsanti precise:** l'alone del pulsante evidenziato segue esattamente la sua forma e non viene più tagliato ai due estremi.
- L'avviso sul **gain audio** («riapri il video») ora **sparisce da solo** dopo pochi secondi.

**Backup e telefono**
- Dalla pagina del telefono (QR) puoi **caricare direttamente un file di backup `.json`** e scegliere se unirlo o sostituire la libreria.
- Il backup può includere anche le **chiavi TMDB, TheTVDB (e PIN) e TorBox**: ripristinandolo, i servizi si **configurano da soli**. (Le chiavi stanno in chiaro nel file: attiva l'opzione solo se il file resta tuo.)

**Impostazioni**
- Organizzate in **categorie**: una fila di pillole in alto (Aspetto, Riproduzione, Contenuti, Metadati, Rete, Servizi, Dati, Informazioni) invece di un'unica lista enorme.

**Home**
- Il titolo in evidenza ora mostra la **copertina più in basso**, senza tagliare il volto.

**Più leggera**
- Aspetto invariato, ma meno lavoro per la TV: l'ombra della selezione, che pesava sulla grafica, è stata sostituita da un alone molto più economico; immagini decodificate in formato più compatto e dissolvenza più breve.

## Tutto il resto (dalle versioni precedenti)
Addon (anche da telefono con QR), Home, Scopri, Cerca con filtri, scheda con stagioni ed episodi, TMDB/TheTVDB, sorgenti ordinate con TorBox, player con tracce, sottotitoli a due livelli con sincronia (ritardo e anticipo), amplificazione audio, timer di spegnimento, Salta intro, **Consigliami**, sfondi e angoli personalizzabili, libreria, backup compatibile con Aether per iPhone.

## Cosa non c'è
- Theater Mode, Google Cast, AirPlay, DLNA, Picture in Picture, download offline: pensati per il telefono.
- **AVI, WMV e audio DTS non sono riproducibili** (servirebbe un decoder FFmpeg).
- Personalizzazione avanzata della Home, registro diagnostico.

## Cosa è stato provato
- ✅ Test automatici (core, TMDB/TheTVDB/fanart con server finti, filmografia, backup con chiavi, parser sottotitoli, consigli), lint bloccante, test dell'interfaccia con telecomando simulato, controllo del pacchetto TV.
- ⚠️ **Non provato su una TV:** logo fanart.tv e apertura immediata del player con TorBox, filmografia dell'attore, tendine di Scopri/Cerca, impostazioni a categorie, caricamento del backup dal telefono, aspetto dell'alone, fluidità.
- Se qualcosa non funziona, apri un'issue con il testo esatto dell'errore.

Il logo del film usa fanart.tv con la chiave di progetto inclusa nell'app (sostituibile in Impostazioni ▸ Metadati).
