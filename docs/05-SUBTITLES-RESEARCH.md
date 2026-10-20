# FASE Alpha 2 — Ricerca: sottotitoli (addon Stremio, OpenSubtitles REST, moviehash)

> Data ricerca: 2026-10-20. Il percorso del file non era stato indicato dal task: ho scelto `docs/05-SUBTITLES-RESEARCH.md`.
> Nessun codice Swift qui. Gli identificatori sono in inglese, la prosa in italiano.

## 0. Come leggere l'affidabilità

| Tag | Significato |
|---|---|
| **[V]** | letto in una fonte primaria durante questo task: repository `Stremio/*` (commit indicati), repository dell'organizzazione `opensubtitles/*`, pacchetto npm `@stremio/stremio-official-addons` |
| **[I]** | letto solo in una fonte secondaria (copia di terzi della OpenAPI, README o codice di client di terzi) oppure dedotto |
| **[M]** | conoscenza pregressa, **non** verificata in questo task |

**Limite della ricerca.** Da questo ambiente non erano raggiungibili: `docs.opensubtitles.com`, `opensubtitles.stoplight.io`,
`trac.opensubtitles.org`, `www.opensubtitles.com` (ToS), `*.strem.io` (manifest live, API) e gli RFC. Erano raggiungibili `raw.githubusercontent.com`,
la ricerca codice di GitHub e il registro npm. Quindi: il manifest live dell'addon non è stato letto (uso lo snapshot del pacchetto ufficiale),
la documentazione REST ufficiale non è stata letta (uso il codice dei client ufficiali `opensubtitles/*` e una copia di terzi della OpenAPI v1.0.1),
i **Termini di servizio non sono stati letti**.

---

## 1. Decisione

1. **Rotta A, addon Stremio `OpenSubtitles v3`: sì, è la via predefinita** (nessuna chiave, nessun account, solo HTTP GET con IMDb id + hash/size/filename).
   Aether già costruisce la richiesta (`AddonService.subtitles`, test `testSubtitleRequestCarriesVideoHashSizeAndFilename`). Manca: calcolo locale dell'hash per
   gli stream HTTP, normalizzazione completa dei codici lingua, decodifica robusta del charset, un'azione esplicita "Aggiungi OpenSubtitles (ufficiale Stremio)".
   **Non preinstallarlo in silenzio**: invia IMDb id, hash, dimensione e nome file a un server di terzi senza alcun accordo pubblico (§2.7).
2. **Rotta B, REST `api.opensubtitles.com`: non ora.** Fase successiva, opt-in, con *chiave API dell'utente* e *account dell'utente* (Keychain).
   Motivi: serve una `Api-Key` per applicazione e un token utente per scaricare (§3); una chiave per applicazione non andrebbe distribuita in un repository MIT pubblico
   (sarebbe estraibile e condivisa da tutti gli utenti; ToS non letti); la quota di download è per-utente e incoerente tra le fonti; i vantaggi (release name, `hearing_impaired`, `moviehash_match`,
   conversione fps/timeshift) non sono necessari per l'MVP.
3. **Hash locale: sì**, per stream `https://` e di rete locale con `Range` (due GET da 64 KiB) solo quando `behaviorHints.videoHash`/`videoSize` mancano (§5).
   Per `http://` pubblico, torrent (`infoHash`), HLS/DASH non si calcola e si invia solo `filename`.

---

## 2. Rotta A — addon Stremio

### 2.1 Manifest ufficiale (snapshot, non live)

Fonte: `@stremio/stremio-official-addons` **2.1.2** (npm, licenza MIT, pubblicato 2026-01-12), file `addons.json`. **[V] come snapshot, il manifest live non è stato letto.**
`OFFICIAL_URLS` in `official-addons-v2/scripts/build.js` e `ENDPOINTS` in `scripts/gen.js` elencano `https://opensubtitles-v3.strem.io/manifest.json` tra gli addon ufficiali (flags `official: true, protected: false`). **[V]**

```json
{
  "id": "org.stremio.opensubtitlesv3", "version": "1.0.0", "name": "OpenSubtitles v3",
  "description": "OpenSubtitles v3 Addon for Stremio",
  "logo": "http://www.strem.io/images/addons/opensubtitles-logo.png",
  "types": ["movie", "series"], "resources": ["subtitles"], "idPrefixes": ["tt"],
  "catalogs": [], "addonCatalogs": [],
  "behaviorHints": {"adult": false, "p2p": false, "configurable": false, "configurationRequired": false}
}
```

Conseguenze: richieste solo per `type` ∈ {movie, series} e id che inizia con `tt` (IMDb/Cinemeta). Un id non-IMDb (`kitsu:`, `yt_id:`…) non va inviato; non c'è `config`.
Il logo è `http://` (ATS: non caricarlo, usare un'icona locale).

### 2.2 Richiesta

Specifica (`stremio-addon-sdk/docs/api/requests/defineSubtitlesHandler.md`) **[V]**:
`type` (movie, series, channel, tv), `id` = **videoId** (id del video, non l'hash), `extra`: `videoHash` ("OpenSubtitles file hash"), `videoSize` (byte), `filename`.

Percorso (coerente con `ResourcePath` di stremio-core e col test di Aether) **[V]**:

```
GET {base}/subtitles/{type}/{videoId}.json
GET {base}/subtitles/{type}/{videoId}/videoHash={hash}&videoSize={bytes}&filename={name}.json     (ordine: videoHash, videoSize, filename; ogni valore URI-component-encoded)
```

Esempio costruito per un episodio (id Cinemeta `{imdb}:{season}:{episode}`; la forma senza extra è stata verificata da terzi con risposta 200, vedi §2.3):

```
https://opensubtitles-v3.strem.io/subtitles/series/tt0944947:1:1.json
https://opensubtitles-v3.strem.io/subtitles/movie/tt0133093/videoHash=8e245d9679d31e12&videoSize=734003200&filename=The%20Matrix%201999.mkv.json
```

(il secondo usa l'hash di `breakdance.avi` come segnaposto, è la stringa del test di un client di terzi, non l'hash reale di quel film).

**Attenzione, incoerenza nella documentazione ufficiale [V]:** `docs/protocol.md` dice ancora "`/subtitles/{type}/{id}.json`, the `id` in this case is the Open Subtitles file hash, while `extraArgs` … is used for `videoID` … and `videoSize`". È la semantica vecchia.
`defineSubtitlesHandler.md` e `stremio-core` (`src/models/player.rs`) usano `id = videoId` e le tre extra sopra: **seguire stremio-core**.

### 2.3 Risposta

Specifica `docs/api/responses/subtitles.md` **[V]**:

| Campo | Req. | Note ufficiali |
|---|---|---|
| `id` | sì | "unique identifier for each subtitle, if you have more than one subtitle with the same language, the id will differentiate them" |
| `url` | sì | URL del file |
| `lang` | sì | "language code for the subtitle, if a valid ISO 639-2 code is not sent, the text of this value will be used instead" |
| `label` | no | testo del selettore; se assente si usa il nome lingua derivato da `lang` |

Il contenitore è `{ "subtitles": [ … ] }` con `cacheMaxAge`, `staleRevalidate`, `staleError` opzionali. In stremio-core il tipo è `Subtitles { id, lang, url, label?: String, fonts: Vec<Url> }` **[V]**.

Risposta reale catturata da terzi il 2026-08-02 (README di `D-dezeeuw/ThunderTV`) **[I]**:

```json
{ "subtitles": [
  { "id": "30949",
    "url": "https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/36919",
    "SubEncoding": "CP1252", "lang": "eng", "m": "i", "g": "11" } ] }
```

Osservazioni di terzi **[I]**: nessun release name e nessun flag hearing-impaired; campi extra non standard `SubEncoding`, `m`, `g` (da ignorare; in un client di terzi `m:"h"` indica un match per hash, `m:"i"` per IMDb id);
CORS aperto (`access-control-allow-origin: *`); il file `…/file/36919` risponde `200 application/x-subrip; charset=utf-8` (≈125 KB). Esistono varianti di URL con parametro `?senc=cp1250` (in un payload di terzi): decodificare con fallback (§2.6).
Il decoder di Aether (`AddonSubtitle`) ignora già i campi sconosciuti e usa `lang="und"` se manca. OK.

Non verificato: se l'addon usi davvero `videoHash` (un client di terzi sostiene "a bogus hash returns the identical list", ma una lista identica è attesa anche se nessun upload corrisponde a quell'hash; un altro client scrive che con l'hash l'addon aggiunge upload "in sync by definition"). Trattare il match per hash come *possibile miglioramento*, non come garanzia.

### 2.4 Come lo usano stremio-core / stremio-web / stremio-video **[V]**

* Richiesta `AggrRequest::AllOfResource(subtitles_path)`: **tutti** gli addon installati che dichiarano `subtitles` per quel tipo/prefisso, in parallelo (`src/models/player.rs`).
* Le extra sono `VIDEO_HASH_EXTRA_PROP="videoHash"`, `VIDEO_SIZE_EXTRA_PROP="videoSize"`, `VIDEO_FILENAME_EXTRA_PROP="filename"` (`src/constants.rs`), tutte `is_required: false`.
* **Precedenza** (`subtitles_update`): `stream.behaviorHints.{videoHash,videoSize,filename}` se presenti, altrimenti `VideoParams {hash, size, filename}`. Se non c'è alcun valore *e* `video_params` è `None`, la richiesta non parte ancora; appena `VideoParamsChanged` arriva (anche con campi nulli) parte con le extra disponibili.
  Il commento di `VideoParams` dice "Opensubtitles hash usually retrieved from a streaming server endpoint".
* `stremio-video` (`src/withStreamingServer/fetchVideoParams.js`, MIT): se `behaviorHints.videoHash` (stringa) **e** `videoSize` (numero) esistono usa quelli senza rete; altrimenti `GET {streamingServer}/opensubHash?videoUrl={url}` → `{"result":{"hash":"…","size":N}}` oppure `{"error":…}`.
  Nome file: `behaviorHints.filename`, altrimenti (torrent) `streamName` da `/{infoHash}/stats.json`, altrimenti `decodeURIComponent(mediaURL.split('/').pop())` (include la query string: in Aether va tolta).
  SDK `stream.md`: `videoHash` "will be used when the streaming server is not connected (so the hash cannot be calculated locally)"; `filename` "highly recommended to set it when using `stream.url`".

### 2.5 Formato dei codici lingua

* Specifica: ISO 639-2 (`subtitles.md`); ma l'esempio di `protocol.md` usa `"lang": "en"` (639-1). **[V]**
* `stremio-web` normalizza con `src/common/languages.ts`: `find(code)` accetta `alpha2`, `alpha3` (`2`, `2B`, `2T`, `3`) e `ietf` della libreria `langs`; `toCode` restituisce il codice 639-2 (`lang['2']`), altrimenti il testo originale. La preferenza utente è un codice a 3 lettere (default `subtitles_language = "eng"`, `interface_language = "eng"`, `src/types/profile/settings.rs`). **[V]**
* `languageNames.json` (186 chiavi, tutte a 3 lettere) **mescola** 639-2/B (`fre`, `ger`) e 639-2/T (`ces`, `nld`, `ell`, `ron`, `slk`, `fas`, `msa`, `mya`, `cym`, `isl`, `mkd`, `kat`, `bod`, `sqi`, `hye`, `eus`, `zho`) e contiene codici non ISO: `pob` ("Português Brazil") e `spl` ("Español (América Latina)"). **[V]**
* Dagli addon reali: la stessa risposta mescola B e T (`cze`, `fre` / `ron`, `ell`) e usa codici inventati da OpenSubtitles: `pob`, `zht` (cinese tradizionale), `zhe` (cinese bilingue). **[I]**
* L'attuale `LanguageCodes` di Aether copre ~20 lingue e mappa `pob → pt` (perde il Brasile). **Raccomandazione:** tabella completa 639-2/B+T+639-3 → 639-1, più alias `pob → pt-BR`, `zht → zh-Hant`, `zhe → zh`, `spl → es-419` (quest'ultimo dedotto dall'etichetta di stremio-web), `por/pt-pt → pt-PT`; confronto sempre dopo normalizzazione; se `lang` non è riconoscibile mostrare il testo grezzo (comportamento dello SDK).
  Il REST usa invece 639-1 minuscolo con varianti: `pt-pt`, `pt-br`, `zh-cn`, `zh-tw` (esempio di `/infos/languages`, §3). **[I]**

### 2.6 Codifica dei file

`…/subencoding-stremio-utf8/…` nel percorso dell'URL = l'addon ricodifica in UTF-8 (osservato da terzi **[I]**; nel campo `SubEncoding` resta la codifica originale). Altri addon possono servire charset legacy.
Lo SDK suggerisce `http://127.0.0.1:11470/subtitles.vtt?from=` per indovinare la codifica: **non esiste su iOS** (nessuno streaming server). Aether deve: decodificare UTF-8 rigoroso → BOM → Windows-1252/codepage indicata da `?senc=` → fallback ISO-8859-1. Per ASS/SSA lo SDK dice di servire il file originale (`.ass`/`.ssa` o inizio `[Script Info]`) e di non convertirlo in VTT.

### 2.7 Limiti, termini, rischi

* Nessun requisito di chiave o autenticazione (osservato da terzi **[I]**; `behaviorHints.configurable: false` **[V]** snapshot).
* **Nessun termine d'uso pubblico trovato** per l'uso dell'host `opensubtitles-v3.strem.io` da client non-Stremio. Un client di terzi lo descrive come "a public unauthenticated endpoint we are a guest on, and it may start refusing us at any time" **[I]**. Il progetto Stremio licenzia il protocollo e l'SDK con MIT, ma questo non è un contratto sull'host.
  Mitigazione: l'addon è un'unità sostituibile (l'utente può installare qualunque addon `subtitles`), errori gestiti senza bloccare il player (timeout, 4xx/5xx → "nessun sottotitolo").
* Privacy: IMDb id, hash, dimensione e nome file vanno a un server di terzi; il file `.srt` è scaricato da `subs5.strem.io`. Dichiararlo nella schermata dell'addon e in `PrivacyInfo.xcprivacy` (nessun tracking, nessun identificatore).
* Limiti di quota/rate: nessuno documentato. Applicare timeout (30–45 s nei client letti: 30 s nel client MCP ufficiale, 45 s in un client di terzi), un solo tentativo di retry, cache per `videoId`+extra e rispetto di `cacheMaxAge`.

---

## 3. Rotta B — REST `api.opensubtitles.com`

**Fonti.** Codice dei client ufficiali dell'organizzazione `opensubtitles` **[V]**: `mcp.opensubtitles.com` (MIT, `src/api-client.ts`), `vlsub-opensubtitles-com` (GPL-3.0, solo fatti letti, nessun codice riusato), `OpenSubtitles-Uploader-PRO` (MIT).
I dettagli dei parametri provengono da una **copia di terzi** della OpenAPI ufficiale (`phdelodder/SubTools`, `open-api.json`, `info.version 1.0.1`, `license MIT`, `termsOfService: https://www.opensubtitles.com/en/tos/`) **[I]**: potrebbe essere datata.

### 3.1 Base URL, autenticazione, intestazioni

| Elemento | Valore |
|---|---|
| Server | `https://api.opensubtitles.com/api/v1`; server VIP `https://vip-api.opensubtitles.com/api/v1` **[I]**; i client ufficiali usano `https://api.opensubtitles.com` + `/api/v1/…` **[V]** |
| `Api-Key` | intestazione obbligatoria su ogni chiamata; è la chiave **dell'applicazione** ("obtained in the user profile of app developer on opensubtitles.com") **[I]**; registrazione sviluppatori: `https://www.opensubtitles.com/en/consumers` (README Uploader PRO) **[V]** |
| `Authorization: Bearer <JWT>` | token **dell'utente** da `POST /login`; obbligatorio per `/download` e `/infos/user`, `/logout` **[V]** (VLSub: "Authentication required for download"; spec: security `Bearer` + `Api-Key`) |
| `User-Agent` | formato documentato `<APP_NAME> v<APP_VERSION>` **[I]**; i client ufficiali lo inviano: `VLSub OpenSubtitles.com v1.3.0`, `OpenSubtitles Uploader PRO v…` **[V]**. Per Aether: `Aether v{versione}`, impostato esplicitamente (il default di URLSession è `…CFNetwork…`). Se sia rifiutato quando manca: **[M]** |
| `Content-Type: application/json` | per i POST |
| `Accept: application/json` | |

**Non riusare chiavi trovate in repository pubblici.** Ho incontrato chiavi `Api-Key` incorporate nel codice di client ufficiali e di terzi: appartengono ad altri soggetti, non sono licenziate ad Aether e non sono riportate qui.

### 3.2 Endpoint che servirebbero

| Metodo e percorso | Uso | Note |
|---|---|---|
| `POST /login` | body `{"username":"…","password":"…"}` | risposta `{"user":{"allowed_downloads":100,"allowed_translations":5,"level":"Sub leecher","user_id":66,"ext_installed":false,"vip":false},"base_url":"api.opensubtitles.com","token":"<JWT>","status":200}` **[I]** (stessi campi nel tipo `LoginResponse` del client ufficiale **[V]**). Limite "1 request per 1 second"; su `401` **smettere di riprovare** con le stesse credenziali ("login is expensive"); le richieste successive vanno sull'host `base_url` (può essere `vip-api.opensubtitles.com`, con cache e rate limit diversi; in quel caso inviare sempre il JWT) **[I]**. Il client VLSub conserva il token 24 h come scelta propria **[V]** |
| `GET /subtitles` | ricerca | §3.3 |
| `POST /download` | body `{"file_id":123}` (+ opzionali `sub_format`, `file_name`, `in_fps`, `out_fps`, `timeshift`, `force_download`) | risposta `{"link","file_name","requests","remaining","message","reset_time","reset_time_utc"}` **[V]** (schema Zod del client ufficiale; VLSub invia il body JSON con solo `file_id`). Il conteggio quota avviene **qui**, non nello scaricamento del file; il `link` vale **≤ 3 ore**, non va messo in cache; il file è sempre UTF-8; `in_fps`+`out_fps` obbligatori per le conversioni **[I]**. Formati da `/infos/formats` (esempio: `srt, sub, mpl, webvtt, dfxp, txt`) **[I]**. Il client MCP li passa come query string con body vuoto: preferire il body JSON dell'esempio ufficiale/VLSub |
| `GET /infos/user` | quota | `{"data":{"allowed_downloads":100,"level":"Sub leecher","user_id":66,"ext_installed":false,"vip":false,"downloads_count":1,"remaining_downloads":99}}` **[I]**; VLSub legge anche `username`, `reset_time` **[V]** |
| `DELETE /logout` | chiude il token | **[V]** |
| `GET /infos/languages` | `{"data":[{"language_code":"en","language_name":"English"}, …]}` | 74 voci nell'esempio; contiene `pt-br`, `pt-pt`, `zh-cn`, `zh-tw` **[I]** |

### 3.3 Ricerca `GET /subtitles` **[V]** per i nomi usati dal client ufficiale; **[I]** per tipi/default dalla OpenAPI

Parametri (tutti opzionali, combinabili): `id`, `imdb_id` (**integer**, senza `tt`), `tmdb_id`, `type` (`movie`|`episode`|`all`, default `all`), `query`, `languages` (virgola, **ordine alfabetico**, es. `en,fr`),
`moviehash`, `moviehash_match` (`include`|`only`), `parent_imdb_id`, `parent_tmdb_id`, `parent_feature_id`, `season_number`, `episode_number`, `year`, `hearing_impaired` (`include|exclude|only`, default include),
`foreign_parts_only` (`exclude|include|only`), `trusted_sources` (`include|only`), `machine_translated` (default `exclude`), `ai_translated` (default `include`), `order_by`, `order_direction` (`asc|desc`), `uploader_id`, `page`.
`moviebytesize` compare nel client MCP ma **non** nella OpenAPI: non inviarlo.

Regole della spec **[I]**: se hai l'id, invia l'id e non `query`; per gli episodi invia `parent_imdb_id` + `season_number` + `episode_number` (se hai l'id univoco dell'episodio, solo `imdb_id`);
invia `moviehash` quando possibile ("`moviehash_match` boolean field will be added… the matching subtitles will always come first"); **evita i redirect HTTP** inviando parametri ordinati alfabeticamente, in minuscolo, senza valori di default, senza zeri iniziali negli id; non usare `order_by` se non serve (più costoso, meno cache).

Mappatura da id Stremio (costruita dalla spec, non eseguita):

```
tt0133093            -> GET /api/v1/subtitles?imdb_id=133093&languages=en,it&moviehash=<16hex>
tt0944947:1:5        -> GET /api/v1/subtitles?episode_number=5&languages=en&moviehash=<16hex>&parent_imdb_id=944947&season_number=1
(intestazioni: Api-Key, User-Agent: Aether v<ver>, Accept: application/json)
```

Risposta (schema OpenAPI **[I]**; stesso schema nel client ufficiale **[V]**): `{"total_pages","total_count","per_page","page","data":[{"id","type","attributes":{ "subtitle_id","language","download_count","hearing_impaired","hd","fps","votes","ratings","from_trusted","foreign_parts_only","ai_translated","machine_translated","upload_date","release","comments","moviehash_match"(se inviato moviehash),"uploader":{…},"feature_details":{"feature_id","feature_type","year","title","movie_name","imdb_id","tmdb_id","season_number","episode_number","parent_imdb_id",…},"url","files":[{"file_id","cd_number","file_name"}]}}]}`.
Il `file_id` (non `subtitle_id`) va a `/download`.

### 3.4 Quote, rate limit, errori

* Ricerca: nessun limite di quota giornaliera documentato; rate limit per IP riportato da client di terzi come **5 richieste/secondo** (commento del limiter di `StremioSubMaker`: "shared per-IP API budget: 5 REST requests / second"; intestazioni `x-ratelimit-limit-second: 5` nelle fixture di `pegarr`), `/login` **1/s** (anche nella OpenAPI). Intestazioni lette da client di terzi: `x-ratelimit-limit-second`, `x-ratelimit-remaining-second`, `ratelimit-remaining`, `ratelimit-reset`, `Retry-After` su 429. **[I]**
* Download: quota **per utente e per livello**, variabile nel tempo. Cifre contraddittorie: esempio OpenAPI `allowed_downloads: 100` ("Sub leecher", dati d'esempio 2020-22); commenti di client di terzi "5/giorno con sola API key", "20/giorno gratis (reset 00:00 UTC)", "200/giorno VIP". **[I] e incoerenti: non codificare cifre; leggere `allowed_downloads`, `remaining_downloads` (da `/infos/user`) e `remaining`/`reset_time_utc` dalla risposta di `/download`.**
  Il README del server MCP ufficiale dichiara per l'uso anonimo (senza chiave né account dell'utente): "Downloads: 0 per day (Kong enforced)", e con una chiave dell'utente "Downloads: Based on your OpenSubtitles account quota" **[V]**.
  Punto non risolto: spec e VLSub richiedono **sia** `Api-Key` **sia** `Authorization: Bearer` per `/download` (VLSub si rifiuta di scaricare senza token), mentre il client MCP scarica inviando la sola chiave utente come `Api-Key`. Non so quale comportamento valga oggi: per Aether presumere che servano entrambi.
* Codici HTTP gestiti dai client ufficiali **[V]**: `401` (chiave/token non validi), `403` (accesso negato / limiti), `404`, `429` ("Download limit reached" / troppe richieste), `503` (servizio non disponibile), `406 No session` (compare in VLSub solo nel percorso XML-RPC legacy, non nel REST). Un `429`: rispettare `Retry-After`, mostrare quota esaurita con `reset_time`.

### 3.5 Termini per app di terze parti

**Non verificati.** L'URL dei ToS è in `info.termsOfService` della OpenAPI (`https://www.opensubtitles.com/en/tos/`), ma non era raggiungibile. Elementi osservati: chiave per applicazione, `User-Agent` con nome e versione dell'app, token per utente, quota per utente. La licenza **MIT** nei file `LICENSE` dei repository `opensubtitles/*` copre *quel codice*, non l'uso dell'API.
Prima di rilasciare la rotta B un umano deve leggere i ToS e la pagina `consumers` (in particolare: distribuzione della chiave in app open source, divieti di caching/ridistribuzione dei sottotitoli, branding).

---

## 4. Algoritmo OpenSubtitles hash (moviehash)

Fonte: `github.com/opensubtitles/oshash` (licenza **MIT**, © 2024 OpenSubtitles), commit `6a9cca3` **[V]**. Origine dichiarata: Media Player Classic (Gabest).

```
hash = file_size + sum_uint64_le(first 65536 bytes) + sum_uint64_le(last 65536 bytes)    (mod 2^64)
```

1. Partire da `file_size` come uint64.
2. Sommare i primi 65.536 byte letti come 8.192 `uint64` **little-endian**; poi gli ultimi 65.536 byte allo stesso modo. Addizione con wrap a 64 bit (senza segno).
3. Uscita: **16 cifre esadecimali minuscole con zeri a sinistra** (`%016x`).
4. **Dimensione minima 131.072 byte** (128 KiB); sotto, non c'è hash valido (l'implementazione Python ufficiale solleva `ValueError`, README: "Minimum file size: 128 KB (131,072 bytes)"). Si leggono sempre solo 128 KiB. A 131.072 byte esatti le due finestre sono adiacenti; sopra, tra le due resta una parte centrale non letta (a 131.080 byte, 8 byte). Le finestre non si sovrappongono mai per file validi.
5. Non è un hash crittografico (dichiarato nel README).
6. Attenzione: l'implementazione Python ufficiale legge con `<q` (con segno) e poi maschera; usando `<Q` (senza segno) il risultato è identico dopo il mascheramento. Nel codice Aether usare `UInt64` con `&+`.

### 4.1 Vettori di test

Ufficiali (README e `CLAUDE.md` di `opensubtitles/oshash`) **[V]**:

| File | Dimensione | Hash |
|---|---|---|
| `breakdance.avi` (`opensubtitles.org/addons/avi/breakdance.avi`) | 12.909.756 | `8e245d9679d31e12` |
| `dummy.rar` decompresso (`dummy.bin`, caso > 4 GiB) | 4.295.033.890 | `61f7751fc2a72bfb` (non riprodotto qui: file non scaricabile) |
| `test-data/testfile.bin` (1 MiB, `random.seed(42)`, `getrandbits(8)`) | 1.048.576 | `e7e2e71e035b137f` |
| `test-data/testfile_small.bin` (`random.seed(123)`) | 131.080 | `6e4ae67790577f76` |
| `test-data/zerohash.bin` (con zeri iniziali) | 131.072 | `00005f1fe0a14000` |

I tre file generati dal repository sono stati **ricostruiti e ricalcolati indipendentemente** in questo task con una mia implementazione (stesso PRNG e costruzione descritta negli script `generate_testfile.py` e `generate_zerohash.py`): tutti e tre gli hash coincidono con quelli pubblicati. **[V]**

Vettori sintetici *senza PRNG*, facili da generare in un test Swift (calcolati qui con la stessa implementazione verificata; **[V]** come calcolo, non pubblicati da OpenSubtitles):

| Costruzione | Dimensione | Hash atteso |
|---|---|---|
| tutti zero | 131.072 | `0000000000020000` (l'hash è la dimensione; copre il padding a 16 cifre) |
| byte `i` = `i & 0xFF` | 131.072 | `a0601fdf9f610000` |
| byte `i` = `(i*7+3) & 0xFF` | 200.000 | `60a0df1f5fa2cd40` (cambiando un byte a metà file l'hash **non** cambia) |
| tutti `0xFF` | 131.072 | `000000000001c000` (wrap a 64 bit) |
| byte `i` = `i & 0xFF` | 131.080 | `a0601fdf9f610008` (stessa somma del caso a 131.072, più 8 della dimensione; buco centrale di 8 byte) |
| testa e coda del caso `(i*7+3)`, dimensione dichiarata 4.295.033.890 | n/a | `60a0df205fa0c422` (solo test della funzione pura `size + head + tail`) |
| testa e coda a zero, dimensione dichiarata 9.223.372.036.854.775.813 | n/a | `8000000000000005` |

---

## 5. Calcolare `videoHash` per stream HTTP (Range)

**Quando serve.** Se `behaviorHints.videoHash` *e* `videoSize` sono presenti, usarli e non fare rete (stessa regola di stremio-video). Se manca solo la dimensione, ricavarla con la sonda sotto.

**Requisiti sul server (standard HTTP, [M]: RFC 9110 non raggiungibile):**

1. Supporto `Range` con risposta `206 Partial Content` e `Content-Range: bytes {start}-{end}/{total}`; `Accept-Ranges: bytes` è un indizio, non una garanzia.
2. Sonda iniziale: `GET` con `Range: bytes=0-65535`. Dal `Content-Range` si legge `total` (= `videoSize`) e si ottengono i primi 64 KiB. Preferibile a `HEAD`, che alcuni server non supportano e che non dà i byte.
3. Seconda richiesta: `Range: bytes={total-65536}-{total-1}` per la coda.
4. Si calcola l'hash sui 128 KiB; nessuna lettura dell'intero file.

**Casi da trattare come "nessun hash" (e passare solo `filename`):**
`200` invece di `206` (server ignora `Range`: **interrompere subito** la richiesta per non scaricare tutto il file), `Content-Range` assente o con totale `*`, `416`, `total < 131072`, lunghezza ricevuta ≠ 65.536, URL `.m3u8`/`.mpd` (HLS/DASH: non c'è un file unico), stream `infoHash`/torrent, `ytId`, timeout.

**Dettagli iOS/URLSession:**

* Impostare `Accept-Encoding: identity` (evita compressione che sfalsa i byte) e ignorare la cache locale per queste richieste. Seguire i redirect, **verificando che l'intestazione `Range` sopravviva** (CDN/debrid reindirizzano spesso; se il secondo host ignora il range, scartare).
* Riutilizzare le stesse intestazioni dello stream (`behaviorHints.proxyHeaders.request`) e il `NetworkPolicy` di Aether (SSRF, redirect, timeout); il limite di 4 MiB per risposta vale, qui si leggono 64 KiB.
* **ATS [M, da verificare su dispositivo]:** `NSAllowsArbitraryLoadsInMediaAndWebContent` (impostato da Aether, `docs/01` §4) vale per i caricamenti media di AVFoundation e WebKit, non per le `URLSession` dati: un `http://` pubblico che AVPlayer riproduce potrebbe far fallire la sonda. Politica proposta: hash solo per `https://` e per host di rete locale (`NSAllowsLocalNetworking`); per `http://` pubblico nessun hash.
* Costo: 2 richieste e 128 KiB per riproduzione; eseguirle in parallelo con l'avvio dell'engine, **mai** bloccare il play. Mettere il risultato in cache per URL (gli URL debrid scadono: non riusarlo oltre la sessione).
* Un hash è valido solo se il file servito è quello originale (non transcodificato/remuxato dal servizio).
* Sequenza consigliata: (1) `behaviorHints`; (2) sonda Range se `https`/LAN e non HLS; (3) `filename` dalle `behaviorHints` o dall'ultimo segmento del percorso URL **senza query**, con percent-decoding; (4) richiesta addon con le extra disponibili.

---

## 6. Altri addon sottotitoli

* **Nessun altro addon è verificabile con le fonti raggiungibili**: il catalogo comunitario ufficiale non è raggiungibile e `stremio-core` non contiene un URL di catalogo community (solo Cinemeta: `https://v3-cinemeta.strem.io/manifest.json`, `https://cinemeta-catalogs.strem.io`). Gli addon "ufficiali" elencati in `stremio-official-addons@2.1.2` sono Cinemeta (`catalog, meta, addon_catalog`), Channels (`catalog, meta`), WatchHub (`stream`), `publicdomainmovies` (`catalog, stream`), OpenSubtitles v3 (`subtitles`) e l'addon locale `127.0.0.1:11470` (`meta, stream`); **solo OpenSubtitles v3 fornisce `subtitles`**. **[V]**
* Visti ma **non raccomandati** (nessuna verifica funzionale o di manifest): `xtremexq/StremioSubMaker` (AGPL-3.0, il suo README elenca come fonti OpenSubtitles, SubDL, SubSource, Wyzie, Stremio Community, Subs.ro; richiede configurazione e alcune chiavi) **[I]**; `Serkali-sudo/strelingo-addon`, `ummugulsunn/stremio-dual-subtitles` (sottotitoli doppi, non verificati).
  Un client di terzi riporta che **Wyzie Subs** (`sub.wyzie.ru`) ora risponde `401 API key required` (2026-08-02), e che SubDL e Subsource richiedono chiavi per utente. **[I]**
* L'utente può comunque installare qualunque addon `subtitles` dalla schermata Addon: la pipeline di Aether è generica (`AllOfResource`). Non ne consigliamo uno nell'interfaccia.

---

## 7. Checklist per chi implementa (rotta A + hash)

1. `AetherCore`: funzione pura `OpenSubtitlesHash` (`size`, `head`, `tail` → stringa 16 hex) con i vettori di §4.1; nessun accesso alla rete nella parte pura.
2. Sonda Range in un tipo separato che usa `HTTPClient`/`NetworkPolicy`; esito `HashResult { hash, size }` o `nil` con motivo (per i log).
3. `AddonService.subtitles`: già invia `videoHash`, `videoSize`, `filename`; aggiungere la precedenza `behaviorHints` → hash locale e la normalizzazione del `filename`.
4. `LanguageCodes`: tabella completa + alias OpenSubtitles (§2.5); mantenere il testo grezzo per codici ignoti.
5. Decodifica sottotitoli: UTF-8 → BOM → `?senc=` → Windows-1252; non convertire ASS in VTT.
6. UI: azione "Aggiungi OpenSubtitles (ufficiale Stremio)" con testo sul dato inviato; nessuna preinstallazione silenziosa; ordinare per lingua preferita, poi per presenza di `label`.
7. Rotta B (opt-in, dopo lettura ToS): chiave utente + login in Keychain, `base_url` dal login, `User-Agent: Aether v…`, un solo login per sessione, cache dei risultati di ricerca, nessuna cifra di quota cablata.

## 8. Questioni aperte / blocchi

* ToS di OpenSubtitles non letti (host non raggiungibile). Bloccante per la rotta B.
* Nessun termine d'uso pubblico per `opensubtitles-v3.strem.io` per client non-Stremio: rischio di blocco senza preavviso (mitigato dalla pluggabilità).
* Manifest live non verificato (snapshot npm del 2026-01-12); documentazione REST ufficiale non letta (copia di terzi v1.0.1).
* Quote gratuite/VIP incoerenti tra le fonti: leggerle a runtime.
* Comportamento reale di `videoHash` sull'addon ufficiale non dimostrato.
* ATS contro `http://` con `URLSession` da verificare su dispositivo.
* Chiavi API incorporate in repository pubblici: non riutilizzare.

## 9. Fonti lette (commit/versioni)

* `Stremio/stremio-addon-sdk` @master v1.6.10 (MIT): `docs/api/responses/subtitles.md`, `docs/api/requests/defineSubtitlesHandler.md`, `docs/api/responses/stream.md`, `docs/protocol.md`.
* `Stremio/stremio-core` @`c4806e8` (MIT): `src/models/player.rs`, `src/constants.rs`, `src/types/resource/subtitles.rs`, `src/types/profile/settings.rs`, `src/types/streaming_server/response.rs`.
* `Stremio/stremio-web` @`bb2405c` (GPL-2.0, solo lettura funzionale): `src/routes/Player/{usePlayer.js,useSubtitles.ts,SubtitlesMenu/SubtitlesMenu.js}`, `src/common/{languages.ts,languageNames.json}`.
* `Stremio/stremio-video` @`61141ee` (MIT): `src/withStreamingServer/fetchVideoParams.js`.
* `Stremio/stremio-official-addons` @master e npm `@stremio/stremio-official-addons@2.1.2` (MIT): `scripts/gen.js`, `official-addons-v2/scripts/build.js`, `addons.json`.
* `opensubtitles/oshash` @`6a9cca3` (MIT): `README.md`, `CLAUDE.md`, `test-data/generate_*.py`, `implementations/python/oshash.py`.
* `opensubtitles/mcp.opensubtitles.com` @master (MIT): `README.md`, `src/api-client.ts`, `src/tools/search-subtitles.ts`. `opensubtitles/vlsub-opensubtitles-com` (GPL-3.0): `vlsubcom.lua`. `opensubtitles/OpenSubtitles-Uploader-PRO` @main (MIT): `README.md`, `src/utils/constants.js`.
* Terzi (secondarie): `phdelodder/SubTools` @`731cf19` `open-api.json`; `D-dezeeuw/ThunderTV` @`6f8643a`; `ventic/ventic` @`9bee935`; `taylanisleyici/ps5plex` @`72208d0`; `xtremexq/StremioSubMaker` @`0a6796c`; `squiter/pegarr`.
