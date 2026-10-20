# Ricerca: API debrid TorBox (per l'integrazione in Aether)

Data della ricerca: 2026-10-20. Documento di sola ricerca, nessun codice dell'app modificato.
Contesto: Aether e un client iOS (Swift/SwiftUI, MIT) che parla il protocollo addon Stremio e non include account/debrid (vedi `01-RESEARCH-MATRIX.md` §2.3 e `02-ARCHITECTURE.md`, "fuori ambito").

## 0. Limite principale di questa ricerca (leggere prima)

Le fonti ufficiali "di prima mano" **non erano raggiungibili** dall'ambiente: `api-docs.torbox.app`, `api.torbox.app/openapi.json`, `torbox.app/terms`, `torbox.featurebase.app` (changelog), `postman.com` (dove api-docs.torbox.app rimanda, secondo una scansione urlscan trovata via ricerca web) e `web.archive.org` sono bloccati dal proxy di egress (`CONNECT tunnel failed, response 403`; `WebFetch` risponde `ENOTFOUND`). Non ho aggirato il blocco. Conseguenze:

* **Non ho letto ne l'OpenAPI ufficiale ne i Termini di Servizio.** Tutto cio che riguarda ToS e limiti di frequenza e non verificato (§6, §3).
* Ho ricostruito il contratto da sorgenti pubbliche lette per intero in questo task:

| Etichetta | Sorgente (letta in clone o pacchetto) | Commit/versione, data | Licenza |
|---|---|---|---|
| **[V]** TorBox-authored | `TorBox-App/torbox-sdk-py` + wheel PyPI `torbox-api` 1.0.6; `TorBox-App/torbox-sdk-js` + npm `@torbox/torbox-api` 1.0.9 (SDK generati dall'OpenAPI ufficiale; le docstring sono le descrizioni ufficiali degli endpoint) | `73b9e167` / `d39a690`, **2025-04-26** | MIT |
| **[V]** TorBox-authored | `TorBox-App/torbox-media-center` (client del team TorBox: `library/http.py`, `functions/torboxFunctions.py`, README, CHANGELOG) | `b92b6b56`, 2026-01-16 | MIT |
| **[C]** client terzi, comportamento reale | `MunifTanjim/stremthru` `store/torbox/*.go` (b66650a, 2026-10-02, MIT); `TheBeastLT/torrentio-scraper` `addon/moch/torbox.js` (3c84f67, 2026-10-18, Apache-2.0); `mhdzumair/MediaFusion` `backend/src/providers/torrents/torbox.rs` (d033749, 2026-10-13, MIT); `Viren070/AIOStreams` `debrid/torbox.ts`, `presets/torbox.ts` (6ca32ed, 2026-10-18, **AGPL-3.0**: letto solo per i fatti, nessun codice riusato) | vedi colonna | vedi colonna |

Legenda delle etichette nel testo: **[V]** letto in sorgente TorBox (SDK/media center); **[C]** letto nel codice di un client terzo aggiornato a ottobre 2026 (prova di comportamento reale, non un contratto); **[I]** dedotto; **[M]** da memoria, non verificato. Gli SDK ufficiali sono vecchi di ~18 mesi: possono mancare campi/endpoint nuovi (es. il POST di `checkcached` non c'e negli SDK ma e usato da tutti i client recenti).

## 1. Base URL, versione, autenticazione, envelope

* Base: `https://api.torbox.app`, versione nel path: `/v1/api/...` **[V]** (`net/environment/environment.py`: `DEFAULT = "https://api.torbox.app"`; `services/torrents.py`: `{base}/{api_version}/api/torrents/...`; media center `TORBOX_API_URL = "https://api.torbox.app/v1/api"`). Health check senza auth: `GET https://api.torbox.app/` **[V]** (`get_up_status`).
* Il motore di ricerca e un host separato (`https://search-api.torbox.app`, Bearer) **[V]** media center; fuori ambito.
* Auth: `Authorization: Bearer <API_KEY>` su quasi tutti gli endpoint **[V]**. **Eccezioni**: `requestdl` (torrents/usenet/webdl) vuole la chiave nel parametro query `token` ("Requires an API key as a parameter for the `token` parameter") e `notifications/rss` (`token`); `torrents/torrentinfo` e `webdl/hosters` non richiedono auth **[V]**. La chiave si copia a mano da `https://torbox.app/settings` **[V]** (README media center). Nei sorgenti letti non esiste un flusso OAuth per app di terzi **[I]**.
* Envelope: `{"success": bool, "error": null | "CODICE", "detail": "testo", "data": ...}` **[V]** (modelli `*OkResponse`: campi `data`, `detail`, `error`, `success`). `data` e lista, oggetto, stringa (requestdl) o null. Tipi incoerenti in produzione ("deal with inconsistent data type", stremthru 0.100.5) e corpi di errore `text/plain` o HTML (stremthru `response.go`, MediaFusion) **[C]**: decodifica **tollerante** obbligatoria.
* Request body: JSON per `checkcached` (POST) e `controltorrent`; `createtorrent` form `application/x-www-form-urlencoded` per i magnet (Torrentio, MediaFusion, stremthru) e `multipart/form-data` per `.torrent` (anche lo SDK dichiara multipart) **[C]/[V]**.

## 2. Endpoint rilevanti (torrents)

### 2.1 `GET /v1/api/user/me?settings=true|false` (Bearer) **[V]**
`data`: `id, created_at, updated_at, email, plan, total_downloaded, customer, server, is_subscribed, premium_expires_at, cooldown_until, auth_id, user_referral, base_email, settings{...}` (modello SDK + `stremthru/store/torbox/user.go`). `plan`: `0` Free, `1` Essential, `2` Pro, `3` Standard (docstring SDK, prezzi 3/10/5 USD datati 2025). Contiene l'email: **non** salvarla ne loggarla. Usarlo per validare la chiave (BAD_TOKEN → chiave errata) e mostrare piano/scadenza.

### 2.2 `checkcached` (disponibilita in cache)
* **GET** `/v1/api/torrents/checkcached?hash=H1,H2&hash=H3&format=list|object&list_files=true` **[V]**: "max di circa 100 hash per richiesta per i limiti URL", prestazioni "< 1 s per 100", "questo endpoint conserva una cache di un'ora"; `format` = `object` o `list` ("list e la piu performante").
* **POST** `/v1/api/torrents/checkcached?format=list&list_files=true` con body JSON `{"hashes": ["<40 hex>", ...]}`, `Authorization: Bearer` **[C]**: Torrentio (`format=list`), stremthru (`format=list&list_files=<bool>`, changelog 0.96.9 del 2026-02-14 "use POST for checkcached"), MediaFusion (`format=object`, a blocchi di **500** hash, commento "POST accepts far more hashes per request than GET query params"; stremthru 0.96.8 "sleep 1s after each 500 hash check"). Limite ufficiale del POST **non documentato negli SDK [V]**: pratica reale 500.
* Risposta (solo gli hash in cache compaiono; gli altri sono assenti) **[C]**:
  * `format=list`: `data` = array di `{name, size, hash, files?:[{name, size, ...}], trackers?, seeds?, peers?}` (struct `CheckTorrentsCachedDataItem` di stremthru).
  * `format=object`: `data` = oggetto con chiave = hash in cache (MediaFusion: "only cached hashes appear as keys").
  * `files[].name` e il percorso completo con cartella radice; **non c'e `id`** del file: l'id per `requestdl` si ottiene solo da `mylist` dopo `createtorrent`. Torrentio legge `short_name`/`opensubtitles_hash` anche qui: trattare ogni campo `files` come facoltativo. `data` vuoto puo essere `null`/`[]`/`{}`.
* Conviene inviare hash minuscoli a 40 hex: i client confrontano le risposte in minuscolo (stremthru, MediaFusion) **[I]**; i magnet con hash base32 vanno convertiti in hex. Esiste un `checkcached` anche per `usenet` (POST in stremthru, GET nello SDK, hash = md5 di link/file) e `webdl` (GET) **[V]/[C]**.

### 2.3 `POST /v1/api/torrents/createtorrent` (Bearer)
Campi **[V]** (`create_torrent_request.py`): `magnet` **oppure** `file` (.torrent); `seed` ("1 auto, 2 seed, 3 don't seed", default 1 o impostazione utente); `allow_zip` ("TorBox zippa solo se il torrent ha >= 100 file"); `name`; `as_queued` ("accoda subito; ignorato per piano Free"). **`add_only_if_cached` non compare in nessuna sorgente letta (SDK, media center, 4 client): [M] solo, non usarlo senza riverifica.** In pratica i client inviano solo `magnet` (+ `allow_zip=false`; stremthru/Torrentio non impostano `seed`).
Risposta **[V]/[C]**: `data: {torrent_id, hash, auth_id}`; se la richiesta viene messa in coda `data.queued_id` al posto di `torrent_id`; il modello SDK elenca anche `active_limit`, `current_active_downloads`. Se il contenuto e in cache: `success:true`, `detail:"Found Cached Torrent. Using Cached Torrent."` (commento stremthru; MediaFusion cerca `"Found Cached"`). Gia presente/accodato: `error:"DIFF_ISSUE"` con `detail` che contiene "already queued"/"maximum queued" (Torrentio); MediaFusion tratta `DIFF_ISSUE` come "TorBox ce l'ha gia" e rilegge `mylist`. Il download parte solo "se l'account ha slot attivi disponibili e il file non e troppo grande" **[V]** (docstring).

### 2.4 `GET /v1/api/torrents/mylist` (Bearer)
Query **[V]**: `bypass_cache` (bool), `id` (restituisce **un oggetto** invece di una lista), `offset` (default 0), `limit` (default **1000**). "Le informazioni si aggiornano ogni 600 s" a meno di `bypass_cache=true`. Commento stremthru: "torbox returns 1 extra item" con `limit` → tagliare lato client **[C]**.
Campi dell'item **[V]** (modello SDK): `id, hash, name, size, magnet, progress, download_state, download_speed, upload_speed, eta, seeds, peers, ratio, availability, active, download_finished, download_present, torrent_file, created_at, updated_at, expires_at, inactive_check, server, auth_id` e `files[]: {id, name, short_name, size, mimetype, md5, s3_path}`. Aggiunte viste nei client **[C]**: `files[].zipped, infected, absolute_path, opensubtitles_hash, hash`; item `owner, private`; il media center (2026-01) legge `cached` (bool) **[V]**, assente nello SDK 2025 → opzionale.
`name` del file = percorso con cartella radice, `short_name` = nome file. Unita/scala di `progress`, `eta`, `download_speed` non verificate (probabili 0–1, secondi, byte/s **[I]**).
`download_state` **[V]** (docstring): `downloading`, `uploading` (seeding), `stalled (no seeds)`, `paused`, `completed` ("non usarlo per sapere se il download e completo"), `cached`, `metaDL`, `checkingResumeData`, piu stati qBittorrent; Torrentio vede anche `seeding`, `uploading (no peers)`, `error` **[C]**.
**Pronto alla riproduzione** = `download_present == true && download_finished == true` (stremthru, MediaFusion); Torrentio usa solo `download_present` **[C]**.

### 2.5 `GET /v1/api/torrents/requestdl` (token in query)
Parametri **[V]**: `token` (API key), `torrent_id`, `file_id`, `zip_link` ("richiesto se manca `file_id`; ha precedenza su `file_id`"), `user_ip` ("IP dell'utente per scegliere la CDN piu vicina. Opzionale"), `redirect`. Senza `redirect`: `data` = **stringa URL CDN** (envelope normale). Con `redirect=true`: risposta 302/307/308 con `Location` verso la CDN (il media center legge `Location`) **[V]**. Per usenet: `usenet_id`; per webdl: `web_id` **[V]**.
Docstring ufficiale **[V]**: i download sono "metered"; il link "si apre per 3 ore" ma la stessa docstring parla anche di "1 hour time limit" per *iniziare* il download (incoerente), dopo l'avvio il tempo e "quasi illimitato". "Permalink" `requestdl?token=APIKEY&torrent_id=N&file_id=N&redirect=true` consigliato **al posto di salvare URL CDN** ("non sono permanenti"); si invalidano **rigenerando la API key** o cancellando l'item. Quindi **il permalink contiene la API key in chiaro**. Cache lato client: stremthru 50 min, media center 3 h **[C]/[V]**.
Gli hostname CDN osservati sono `tb-cdn.cx/.earth/.io/.pw/.st` (config stremthru) **[C]**: possono cambiare, non cablarli.

### 2.6 `POST /v1/api/torrents/controltorrent`
JSON `{"torrent_id": int, "operation": "...", "all": bool}`. Operazioni: `reannounce`, `delete`, `resume` **[V]**; `pause` (stremthru) e `stop_seeding` (Torrentio) **[C]**. `delete` cancella **in modo permanente** dall'account. Altri: `GET torrents/exportdata?torrent_id&type=magnet|file`, `GET|POST torrents/torrentinfo` (hash, `timeout` default 10 s, senza auth), `queued/getqueued?type=torrent&bypass_cache=true` e `queued/controlqueued` **[V]/[C]**.

### 2.7 Usenet e web download (una riga)
Stessa forma con prefissi `usenet/` (`createusenetdownload`: `link|file`, `name`, `password`, `post_processing`, `as_queued`; `usenet_id`; piano Pro per l'uso di stremthru) e `webdl/` (`createwebdownload`: `link`, `name`, `password`, `as_queued`; `web_id`; `webdl/hosters`) **[V]/[C]**. Non necessari ad Aether.

## 3. Errori, limiti, rate limit

* Il discriminante affidabile e il campo `error` nel JSON, non lo status HTTP: Torrentio ignora lo status e guarda `success`; AIOStreams nota che alcune risposte (rate limit, gateway) hanno solo `detail` e vanno classificate col solo status **[C]**. La mappa **status HTTP ↔ codice non e verificata** (non l'ho trovata in nessuna sorgente).
* Codici `error` visti nei client **[C]** (stremthru `error.go` + Torrentio + MediaFusion + AIOStreams; solo i *nomi* sono verificati, il significato e dedotto **[I]**):
  * Auth: `NO_AUTH`, `BAD_TOKEN`, `AUTH_ERROR`, `OAUTH_VERIFICATION_ERROR`, `NOT_ALLOWED`.
  * Piano/limiti: `PLAN_RESTRICTED_FEATURE`, `ACTIVE_LIMIT` (slot attivi esauriti), `COOLDOWN_LIMIT` (cfr. `cooldown_until` in `user/me`), `MONTHLY_LIMIT`, `DOWNLOAD_TOO_LARGE`, `TOO_MUCH_DATA`, `RATE_LIMIT_EXCEEDED`.
  * Richiesta: `INVALID_OPTION`, `INVALID_INPUT`, `MISSING_REQUIRED_OPTION`, `TOO_MANY_OPTIONS`, `BOZO_TORRENT`, `BOZO_NZB`, `BOZO_RSS_FEED`, `DUPLICATE_ITEM`, `DIFF_ISSUE`, `ITEM_NOT_FOUND`, `ENDPOINT_NOT_FOUND`, `LINK_OFFLINE`, `INVALID_DEVICE`.
  * Server: `DATABASE_ERROR`, `UNKNOWN_ERROR`, `REDIRECT_ERROR`, `SELLIX_ERROR`, `DOWNLOAD_SERVER_ERROR`, `NO_SERVERS_AVAILABLE_ERROR`, `SEARCH_ERROR`, `VENDOR_DISABLED` (+ `DOWNSTREAM_ERROR`, `REQUEST_FAILED` in MediaFusion).
* HTTP 429: stremthru legge l'header `Retry-After` se presente; il media center fa backoff esponenziale (1.5·2^n, 5 tentativi, timeout 60 s) **[C]/[V]**. README media center: l'endpoint di *ricerca* e soggetto a rate limit e "i 429 saranno comuni"; la modalita `instant` (refresh ogni 6 minuti) "puo causare rate limiting" **[V]**.
* **Numeri dei rate limit: non trovati in nessuna sorgente letta.** Ricordo (M, bassa confidenza) limiti per-minuto generali e piu stretti sugli endpoint di creazione, ma non riporto cifre: il client deve adattarsi (429 + `Retry-After`, `RATE_LIMIT_EXCEEDED`, `COOLDOWN_LIMIT`).
* Limiti di piano: slot di download attivi (`active_limit`), dimensione massima per download, quota mensile; usenet richiede piano Pro (stremthru `HasUsenet` solo per `PlanPro`) **[C]**; `as_queued` ignorato in piano Free **[V]**.

## 4. Cosa significa "Instant" per TorBox

* Nelle sorgenti lette "instant" = **contenuto gia presente nella cache condivisa di TorBox**: `checkcached` lo dice, `createtorrent` risponde "Found Cached Torrent. Using Cached Torrent." e il file e subito disponibile senza attendere un download (MediaFusion: "Check which hashes are *instantly cached* on TorBox") **[C]**. La cache `checkcached` e a sua volta memorizzata 1 ora → puo essere in ritardo **[V]**.
* L'addon Stremio ufficiale TorBox vive su `https://stremio.torbox.app/<API_KEY>/manifest.json` (risorse `stream`, `meta`, `catalog`) e marca i flussi in cache con `Instant` / `Your Media` nel `name` e `Click play to start` nella `description` (AIOStreams `presets/torbox.ts`, `config/schema/presets.ts:254`) **[C]**: e un'etichetta di stream, non un prodotto.
* **Non ho trovato alcun prodotto/endpoint chiamato "TorBox Instant".** Nel media center `instant` e solo un valore dell'intervallo di refresh (`0.1` ore = 6 min) **[V]**. (Uno snippet di ricerca cita il changelog di febbraio 2026: "adding a cached download now requests TorBox to generate the download link in the background" **[I]**, non letto in originale.)

## 5. Come lavorano i resolver esistenti

Flusso comune (Torrentio, stremthru `AddMagnet`/`GenerateLink`, MediaFusion) **[C]**:

1. `POST checkcached` sugli `infoHash` degli stream (blocchi, `format=list|object`) → badge "in cache".
2. Alla pressione di play: (MediaFusion) `mylist?bypass_cache=true` per vedere se l'hash e gia nell'account e `queued/getqueued`; altrimenti `POST createtorrent` (`magnet=magnet:?xt=urn:btih:<hash>&tr=...`, `allow_zip=false`).
3. `GET mylist?id=<torrent_id>&bypass_cache=true` (stremthru: subito dopo l'add; ritenta fino a 3×5 s) finche `download_present && download_finished`; se `queued_id`/non pronto → "in download".
4. Scelta del file → `requestdl` (JSON, `user_ip` = IP del client finale) oppure URL permalink `requestdl?...&redirect=true`; Torrentio/MediaFusion restituiscono lo URL permalink (con `token`) come redirect.

Scelta del file per un episodio (la chiave: **`fileIdx` di Stremio NON e l'`id` di TorBox**):
* stremthru usa `MatchFileByIdx` **solo per RealDebrid** (`storeCode != RealDebrid → nil`); per TorBox ordine: nome file (`behaviorHints.filename`) → pattern `season:episode` del Stremio id (PTT sul nome file) → `fileIdx`(no) → regex opzionale → **file video piu grande**; con il fallback "largest" non marca lo stream come corretto.
* Torrentio: filtra i video (`isVideo(short_name)`), ordina per `size` desc, se `fileIdx` e intero cerca per **nome** con `sameTorboxFilename` (confronto esatto oppure normalizzato: `&`→`and`, rimozione di tutto cio che non e lettera/cifra Unicode), altrimenti il piu grande; se tutti i file sono `zipped` → errore "archivio".
* MediaFusion: filename esatto → `season/episode` (PTT, poi pattern di fallback) → `fileIdx` solo come indice **posizionale** nell'array `files` e mai prioritario rispetto al match per nome → piu grande.
* `files[].id` per `requestdl` si legge sempre da `mylist` (non da `checkcached`).

## 6. ToS, licenze, uso da parte di app terze

* **Termini di servizio: NON letti** (pagina bloccata). Quindi non posso affermare cosa vietino. Elementi verificati altrove **[V]**: README del media center (team TorBox): "TorBox does not allow piracy or condone it in any way. This is meant to be used with media you own and have the rights to"; "'Repairing' or 'renewing' your library (this is against TorBox ToS)" (rimettere in coda/rinnovare item per aggirare la scadenza e vietato); "A TorBox account. Must be on a paid plan"; docstring `requestdl`: link "metered", niente condivisione a lungo termine, permalink invalidabili rigenerando la chiave.
* Secondari non verificati **[I]** (snippet di ricerca, non letti in originale): una FAQ citata su forum ("multiple IPs per account consentiti, non condividere i link privati in aperto"); changelog del 2026-05-22 (sistema anti-abuso che colpisce "top 0.001%" per banda); articoli su un aggiornamento dei ToS ("neutral technology service", indennizzo).
* Uso con la **chiave dell'utente** da parte di app terze: TorBox stesso pubblica SDK ufficiali MIT (py/js/go/php/java/.NET) e un addon Stremio con la chiave nell'URL, e molti client open source la usano (**[V]/[C]**). Non ho letto una clausola che lo consenta o lo vieti esplicitamente: va confermata sui ToS prima del rilascio.
* Licenze del codice TorBox: organizzazione `TorBox-App` — "most items are licensed under ELv2 ... anything not marked with ELv2 is MIT" (README `.github`); SDK e media center sono **MIT** **[V]**. Aether non incorpora codice TorBox (client scritto da zero in Swift): nessun obbligo di attribuzione, ma `docs/03-LICENSES.md` dovrebbe citare TorBox come servizio terzo (non come dipendenza).
* Regole operative derivate **[I]**: non codificare mai una chiave nel binario; non usare codici referral dell'app; non fare da proxy/cache condivisa tra utenti; `user_ip` omesso (chiamate dirette dal dispositivo) — MediaFusion rimuove `user_ip` del proxy perche "pins TorBox to a CDN edge near the proxy"; niente polling/rinnovo massivo.

## 7. Decisione e client minimo sicuro per Aether

**Decisione**: (a) subito, senza codice: documentare che l'addon ufficiale `https://stremio.torbox.app/<API_KEY>/manifest.json` (e Torrentio con TorBox) si installa gia come qualsiasi addon e restituisce stream `url` riproducibili; l'URL con la chiave finisce gia nel Keychain (`02-ARCHITECTURE.md`, "Installazione addon"). (b) Come feature opt-in disattivata di default: un client TorBox **nativo e minimo** in `AetherCore` per risolvere gli stream `infoHash` degli addon torrent, **solo per contenuti gia in cache**, con chiave fornita dall'utente. Rinviare l'aggiunta di torrent non in cache.

Design (nessun codice):
1. **Superficie**: protocollo `DebridProvider` nel Core + implementazione TorBox sopra `HTTPClient`/`NetworkPolicy` esistenti. Host fisso `api.torbox.app` (non configurabile: la chiave non deve mai andare altrove); su redirect verso altro host togliere `Authorization`; https obbligatorio.
2. **Segreti**: chiave solo in `SecretStore`/Keychain; mai in backup/export/log (il `Redactor` gia oscura `token` e `Authorization`); mai dentro URL salvati (libreria, cronologia, download, Cast/DLNA). Identificare i contenuti per `infoHash` + percorso file, non per URL.
3. **Validazione**: `GET user/me?settings=false` → conservare solo `plan`, `is_subscribed`, `premium_expires_at`; scartare `email`. Piano Free (`0`) → avviso (limiti, `as_queued` ignorato).
4. **Disponibilita**: `POST checkcached?format=list&list_files=true`, body `{"hashes":[...]}`, hash minuscoli 40 hex, blocchi **≤ 100**, 1–2 richieste in parallelo, solo per gli stream visibili; cache in memoria ~1 h (come il server). Mancante = "non in cache" (non errore).
5. **Riproduzione (solo in cache)**: `POST createtorrent` (form: `magnet`, `allow_zip=false`; niente `seed`/`as_queued`) → leggere `torrent_id` → `GET mylist?id=<id>&bypass_cache=true` (intervallo ≥ 3 s, massimo ~60 s) finche `download_present && download_finished` → scelta file (punto 6) → `GET requestdl?token=…&torrent_id=…&file_id=…` **senza** `redirect`, `user_ip` omesso → `data` e l'URL CDN da passare a `AVPlayer`. Prima dell'add controllare `mylist` per l'hash (evita `DIFF_ISSUE`/duplicati); `DIFF_ISSUE`/`DUPLICATE_ITEM` ⇒ rileggere `mylist`, non ritentare l'add. Non memorizzare l'URL CDN oltre la sessione di riproduzione (rigenerarlo se la CDN risponde 403/410).
6. **Selezione file (puro, testabile)**: candidati = `files[]` video (`mimetype` `video/*` o estensione nota), escludendo `zipped`/`infected`; ordine: `behaviorHints.filename` (confronto normalizzato come Torrentio) → `season/episode` dell'id Stremio (`tt…:S:E`) dal nome file → film: file video piu grande; `fileIdx` solo come suggerimento posizionale e mai primario. Per le serie senza corrispondenza **non** scegliere il piu grande: mostrare la lista dei file video all'utente.
7. **Errori**: mappare il campo `error` (non lo status) in messaggi localizzati: auth (`BAD_TOKEN`, `AUTH_ERROR`, `NO_AUTH`) → richiedere nuova chiave, nessun retry; `PLAN_RESTRICTED_FEATURE`, `ACTIVE_LIMIT`, `MONTHLY_LIMIT`, `COOLDOWN_LIMIT`, `DOWNLOAD_TOO_LARGE` → messaggio all'utente, nessun retry automatico; 429/`RATE_LIMIT_EXCEEDED`/5xx/HTML → backoff esponenziale con jitter (rispetto di `Retry-After`), max 3 tentativi; timeout 15 s. **Mai** cancellare/mettere in pausa item dell'utente in automatico (Torrentio lo fa per liberare slot: da non replicare) e mai cicli di "repair/renew" (contrari ai ToS secondo il README TorBox).
8. **Decodifica tollerante**: tutti i campi opzionali; `FlexInt`/`FlexString`, `data` come `null`/lista/oggetto/stringa; corpi non-JSON ⇒ errore di servizio.
9. **Test**: server di fixture con envelope reale (`success/error/detail/data`), casi cached/uncached/queued/DIFF_ISSUE/429/HTML; test di redazione della chiave nei log; test della scelta file con nomi `&`/Unicode e archivi.
10. **UX/compliance**: testo onesto "usa il tuo account TorBox; contenuti di cui hai diritto"; nessuna promozione, nessun referral.

## 8. Cosa e certo e cosa no

| Certo (letto in sorgente) | Non certo / non trovato |
|---|---|
| Base `https://api.torbox.app/v1/api`, Bearer; `requestdl` con `token` in query **[V]** | Contenuto di api-docs/OpenAPI attuale e dei ToS **(non letti)** |
| Envelope `success/error/detail/data` **[V]** | Mappa status HTTP ↔ `error`; presenza costante di `Retry-After` |
| `user/me`, `mylist`, `requestdl`, `controltorrent` con i parametri sopra **[V]** | **Numeri** dei rate limit; limite ufficiale del POST `checkcached` (pratica: 500) |
| GET `checkcached` (~100 hash, cache 1 h) **[V]**; POST `{hashes}` + `format`/`list_files` **[C]** | `add_only_if_cached` (**[M]**, mai visto); campi esatti di `checkcached` `files` |
| `createtorrent` campi `magnet/file/seed/allow_zip/name/as_queued` **[V]** | Scala/unita di `progress`, `eta`, `download_speed`; `cached` in `mylist` (**[V]** solo nel media center) |
| `fileIdx` Stremio ≠ `file.id` TorBox; scelta per nome/SxxExx/piu grande **[C]** | Durata esatta del link (3 h vs 1 h nella stessa docstring) |
| Nessun prodotto "TorBox Instant" nelle fonti; "instant" = in cache **[C]/[V]** | Clausole ToS su app terze, cache dei link, `user_ip`, abuso |
| SDK ufficiali MIT, org TorBox: ELv2 salvo dove marcato MIT **[V]** | Aggiornamenti API successivi ad aprile 2025 (SDK) |

## 9. Da riverificare appena la rete lo consente

1. Scaricare `https://api.torbox.app/openapi.json` (o la collezione Postman di `api-docs.torbox.app`) e confrontare: POST `checkcached` (schema, limite), `createtorrent` (`add_only_if_cached`), `mylist` (`cached`), tabella errori/status, sezione rate limit.
2. Leggere `https://torbox.app/terms` (e la pagina abuso) per: uso da app terze con chiave utente, cache/condivisione link, `user_ip`.
3. Chiamata reale con una chiave di prova: `user/me`, `checkcached` (1 hash noto in cache), verifica di `Retry-After` su 429.
