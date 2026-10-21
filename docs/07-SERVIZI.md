# Servizi opzionali: TorBox, TMDB, TheTVDB, OpenSubtitles

Nessuno di questi servizi è obbligatorio e Aether **non include nessuna chiave**: ogni chiave è dell'utente, si inserisce in *Altro ▸ Impostazioni ▸ Servizi*, vive nel Portachiavi di iOS
(`ThisDeviceOnly`, mai nei backup, mai nei log) e si può rimuovere in qualsiasi momento. Senza chiavi l'app funziona come prima.

Le «Verificato» qui sotto vengono dal workflow manuale `API probe` (`docs/research/api-probe-2026-10-20.md`), che legge le fonti pubbliche da un runner GitHub senza credenziali.
Tutto ciò che richiede un account reale (risposte con chiave valida) **non è stato verificato**: il comportamento con una chiave valida è provato solo contro fixture costruite dalla documentazione.

## TorBox (debrid)

**Dove e come, nell'app.** *Impostazioni ▸ Servizi ▸ TorBox*: chiave in un campo protetto (dopo il salvataggio non viene più mostrata: «Chiave salvata nel Portachiavi» e «Rimuovi la chiave»), «Salva» salva e
controlla subito `user/me` (una chiave rifiutata da TorBox non viene tenuta), stato reale («Connesso a TorBox · piano X», scadenza solo se l'API la restituisce, mai e-mail né chiave), motivi in italiano per chiave non valida,
piano che non consente la funzione, limite di richieste, servizio irraggiungibile, pagina di errore del gateway. Con una chiave salvata, nella lista delle sorgenti i torrent diventano riproducibili: ognuno mostra «Verifica…» e poi
«In cache» / «Non in cache» (niente se la verifica non è riuscita); un tocco su «In cache» risolve il link (con avanzamento annullabile) e avvia la riproduzione; un tocco su «Non in cache» chiede «Avvia il download su TorBox?» e poi
mostra percentuale, velocità e tempo stimato finché è pronto, o finché l'utente annulla. Senza chiave la riga resta «non riproducibile» con il suggerimento di configurare TorBox in *Impostazioni ▸ Servizi*. Il player non avvia mai un
download per conto suo: risolve solo contenuti già in cache o già preparati dalla lista. Dall'episodio successivo in automatico Aether sceglie solo un torrent confermato in cache. Un contenuto TorBox non si può trasmettere con il casting
(il link contiene un token che non viene consegnato a Google Cast né ai ricevitori DLNA; con AirPlay, invece, il ricevitore scelto riceve il link: usarlo solo su un dispositivo proprio).

**Cosa lascia nell'account.** Per ottenere il link di un torrent già in cache Aether invia una `createtorrent` con `add_only_if_cached=true` (come fa Nuvio): TorBox risponde con l'elemento solo se è davvero in cache (altrimenti HTTP 409) e **non avvia nessun nuovo download**,
quindi funziona anche quando TorBox ha sospeso temporaneamente i *nuovi* download (periodo di attesa). Solo se l'utente ha confermato «Avvia il download su TorBox?» e il torrent non è in cache, Aether ripete l'aggiunta senza `add_only_if_cached`; un'attesa annullata lascia il torrent nell'account.
Aether non cancella nulla.

**Cos'è e cosa fa Aether.** TorBox è un servizio a pagamento che scarica torrent sui propri server e li serve in HTTPS. Aether, con la chiave dell'utente: (1) controlla se un torrent è già in cache (`checkcached`);
(2) se lo è, ottiene il link di download del file giusto (`createtorrent` con `add_only_if_cached=true` per far comparire l'elemento nella lista dell'utente se non c'è già, poi `mylist` e `requestdl`) e lo riproduce; (3) se non lo è, **solo dopo una conferma
esplicita**, aggiunge il torrent e mostra l'avanzamento (percentuale, velocità, tempo stimato) finché è pronto. Aether non cancella, mette in pausa né «ripara» mai gli elementi dell'utente.

**Terminologia.** Non esiste un endpoint «TorBox Instant». «Istantaneo» significa che il torrent è *in cache* (già scaricato da TorBox): il link è disponibile subito. Aether scrive «In cache» solo quando `checkcached` lo ha detto,
e non scrive nulla quando la verifica non è riuscita (un errore di rete non è mai «non in cache»).

**Verificato (2026-10-20).** Specifica OpenAPI pubblica: percorsi `user/me`, `torrents/checkcached` (GET e POST), `createtorrent` (multipart), `mylist`, `requestdl` (`token`, `torrent_id`, `file_id`, `zip_link`, `user_ip`, `redirect`),
`controltorrent`, `asynccreatetorrent`, `user/auth/device/*`. Errore con chiave non valida: HTTP 403 `{"success":false,"error":"AUTH_ERROR",...}`; senza intestazione `Authorization`: HTTP 401 `{"detail":"Not authenticated"}`.
Intestazioni di limite: `x-ratelimit-limit: 300`, `x-ratelimit-remaining`, `x-ratelimit-reset`, `retry-after: 60`.

**Riferimento (Nuvio).** Il flusso con `add_only_if_cached` è stato letto nel sorgente pubblico di Nuvio (GPL-3.0, usato solo come riferimento di lettura: nessun codice copiato). Nuvio invia `magnet`, `allow_zip=false` e `add_only_if_cached=true`; un HTTP 409 significa «non in cache». Ciò che Aether fa con la risposta è coperto da stub, **non da una prova con un account TorBox reale**.

**Non verificato.** Le condizioni d'uso di TorBox (la pagina è renderizzata lato client e non si legge senza browser): l'uso di Aether è limitato a ciò che l'utente chiede, con la sua chiave, senza automatismi di massa.
Il flusso «device code» (`user/auth/device/*`) esiste ma non è usato. I campi delle risposte con un account reale sono letti in modo tollerante e coperti da fixture, non da prove dal vivo. Piani e limiti dell'account dell'utente non sono interpretati.

**Come è provato.** Core: stub HTTP costruiti dalla documentazione (`DebridTests`, 5 test di contratto con il corpo delle risposte del server di prova); app: test unitari dello stato e della logica della lista; test UI contro `Tools/FixtureTorBoxServer` (un server
Node di prova che imita gli endpoint documentati, chiave `test-key`, sei modalità di errore). Il server di prova è un'assunzione costruita dalla documentazione: **TorBox reale non è stato mai contattato**. In particolare il link reale potrebbe non avere
estensione: allora il contenitore viene dal nome del file (un MKV va a MPV se disponibile, altrimenti compare il messaggio di formato non supportato).

**Sicurezza.** La chiave viaggia in `Authorization: Bearer` (tranne `requestdl`, che la richiede in query: quell'URL non viene mai registrato); il client rifiuta host diversi da `api.torbox.app` (https); l'URL di download restituito
contiene un token e non compare nei log né nei messaggi d'errore; `createtorrent` non viene mai ritentato automaticamente.

**Il link restituito può contenere la chiave (Beta 2).** `requestdl` è chiamato come fa Nuvio (`zip_link=false`, `redirect=false`, `append_name=false`, nessun `user_ip`). Con un account reale il link che TorBox restituisce conteneva la chiave dell'account
e Nuvio lo riproduce così com'è: in Beta 1 Aether lo rifiutava («il link restituito contiene credenziali») e il video non partiva. Ora è accettato, ma trattato come un segreto: resta in memoria per la sola sessione di riproduzione, non viene
scritto nei log né in nessun messaggio d'errore, non viene salvato, e non viene consegnato a Google Cast né ai ricevitori DLNA (i contenuti TorBox non si trasmettono con questi). **Con AirPlay il ricevitore che scegli riceve il link, chiave compresa** (il sistema lo passa al televisore o all'Apple TV). Un link con la chiave su **http** (non cifrato) è rifiutato.
**Limite noto:** i file che passano da MPV (MKV e altri contenitori non nativi) viaggiano senza verifica del certificato TLS (vedi `08-ALPHA-2-NOTE.md`): su una rete ostile un attaccante «man in the middle» potrebbe leggere la chiave dal link. Non provato su un dispositivo.

## IntroDB («Salta intro» e «Salta riassunto»)

Il pulsante compare durante l'intro e durante il riassunto di un episodio, e porta alla fine di quella parte. I tempi vengono da **IntroDB** (introdb.app), un database di tempi inseriti dalla comunità: nessun account, nessuna chiave.

**Cosa viene inviato.** Solo il codice IMDb del titolo (`tt…`), la stagione e l'episodio, a `https://api.introdb.app`. Niente identificativi del dispositivo, niente nome del file, niente indirizzi di sorgenti. Si spegne in *Impostazioni ▸ Riproduzione ▸ Episodi* («Mostra Salta intro e Salta riassunto»); da spento non parte nessuna richiesta. Il codice IMDb si ricava dall'id del titolo: per titoli di cataloghi che non usano IMDb (per esempio `kitsu:`) il pulsante non compare.

**Verificato (2026-10-21, da un runner di GitHub, senza credenziali).** `GET https://api.introdb.app/segments?imdb_id=tt0944947&season=1&episode=1` risponde HTTP 200 `application/json` con `intro`, `recap`, `outro`, `post_credits` (oggetti con `start_sec`, `end_sec`, `start_ms`, `end_ms`, `confidence`, `submission_count`, `updated_at`, oppure `null`) e i flag `no_intro`, `no_recap`, `no_outro`. Per quell'episodio l'intro va da 437 s a 531 s. Esiste anche `GET /intro` (solo intro). Il test `SkipSegmentsTests` usa quella risposta reale.

**Cosa fa Aether con la risposta.** Usa solo intro e riassunto (i titoli di coda non sono usati). Scarta i tempi privi di senso (fine prima dell'inizio, meno di 3 s, più di 10 minuti). Offre il pulsante da 1 s prima dell'inizio fino a 1 s prima della fine, e non lo offre se il segmento finisce oltre la durata del file (un'altra versione dell'episodio). Le risposte restano in memoria (24 ore se trovate, 6 ore se IntroDB non sa nulla), richieste uguali contemporanee diventano una sola, e dopo un errore o un limite di richieste Aether smette di chiedere per un po'. Un errore non mostra nulla: semplicemente non c'è il pulsante.

**Non verificato.** Le condizioni d'uso e i limiti di richieste di IntroDB (la pagina di documentazione è lato client e non si legge senza browser). La qualità dei dati: sono contributi della comunità per un certo montaggio dell'episodio, e con un file diverso i tempi possono essere sfasati di alcuni secondi o mancare. Sul dispositivo non è stato provato. Esiste un servizio con nome simile, TheIntroDB (theintrodb.org), con un'altra API; da un runner di GitHub risponde con una pagina di verifica di Cloudflare, quindi non è usato.

## TMDB

Metadati arricchiti (locandine, sfondi, logo, trama, cast, registi, durata, anno, titoli e trame degli episodi) **solo dove l'addon non li fornisce**: un dato dell'addon non viene mai sovrascritto, e la valutazione di TMDB non viene mai messa nel campo «IMDb».
Sono usati il token di lettura v4 oppure la chiave v3 (riconosciuti dalla forma), le immagini arrivano solo da `image.tmdb.org`, e dopo una chiave rifiutata, un limite di richieste o un'interruzione Aether smette di chiedere per un po'
(5 minuti, il tempo indicato da `Retry-After`, 20 secondi) invece di ripetere la stessa richiesta per ogni titolo. Le risposte sono in cache 24 ore. **Il logo di TMDB non è incluso**: c'è il testo di attribuzione, ma il materiale
ufficiale non è stato scaricato né verificato; va aggiunto prima di una distribuzione pubblica più ampia. Pagina: *Impostazioni ▸ Servizi ▸ TMDB* (stessa cura della chiave: campo protetto, verifica, rimozione). **Verificato**: la specifica OpenAPI usa il token di lettura API v4 (`Authorization: Bearer`); la chiave v3
(`api_key` in query) risponde ancora (con chiave non valida: HTTP 401 `status_code 7`); `GET /3/find/{id}?external_source=imdb_id|tvdb_id`, `/3/movie/{id}`, `/3/tv/{id}`, `/3/tv/{id}/season/{n}`, `/3/search/multi`, `/3/configuration`.
**Condizioni lette**: l'uso commerciale richiede un accordo scritto; Aether è gratuito e open source, la chiave è dell'utente; l'attribuzione («This product uses the TMDB API but is not endorsed or certified by TMDB.») è mostrata
dove compaiono dati TMDB e nelle Impostazioni.

## TheTVDB v4

Usato **solo** per titoli, trame e immagini degli episodi che né l'addon né TMDB conoscono (ricerca per id IMDb, poi episodi nella lingua dell'utente). Pagina: *Impostazioni ▸ Servizi ▸ TheTVDB* (chiave e PIN facoltativo).

`POST /v4/login` con `{"apikey": "...", "pin": "..."}` (il `pin` solo per le chiavi «user-supported») restituisce `data.token` valido un mese; con chiave non valida: HTTP 401 `{"status":"failure","message":"InvalidAPIKey: ..."}` (verificato).
I percorsi dei dati (`/search/remoteid`, `/series/{id}/extended`, …) sono scritti sulla documentazione ufficiale della v4 ma **non sono stati confermati** dal probe di questa data; le risposte sono lette in modo tollerante. Le condizioni
d'uso/attribuzione non sono state lette (la pagina informativa è stata scaricata ma il filtro del probe non ne ha estratto il testo): l'app mostra un credito a TheTVDB dove usa i suoi dati.

## OpenSubtitles

Via addon Stremio ufficiale `org.stremio.opensubtitlesv3` (`https://opensubtitles-v3.strem.io/manifest.json`), senza chiave né account. **Verificato**: risorsa `subtitles` per `movie`/`series` con prefisso `tt`; risposta con lingua ISO 639-2
(`pob` = portoghese brasiliano), `SubEncoding`, `fpsMilli`, `releaseGroup`; il file arriva già ricodificato in UTF-8; gli extra `videoHash`/`videoSize` sono accettati (il comportamento con un hash realmente corrispondente non è stato osservato).
L'API REST di OpenSubtitles (chiave per applicazione + token utente) **non** è usata in Alpha 2: servirebbe una chiave dell'applicazione e condizioni d'uso non lette.
Aether calcola l'hash OpenSubtitles del file (due richieste `Range` da 64 KiB) solo per sorgenti HTTPS dirette e solo se l'addon non dichiara già `videoHash`/`videoSize`.
