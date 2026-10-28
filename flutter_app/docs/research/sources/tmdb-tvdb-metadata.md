# TMDB e TheTVDB

**Fonti** (2026-10-28)
- TMDB — https://developer.themoviedb.org/docs — **non raggiungibile**.
- TheTVDB — https://thetvdb.com/api-information — **non raggiungibile**; letta la specifica OpenAPI v4 su https://raw.githubusercontent.com/thetvdb/v4-api/main/docs/swagger.yml (200, 115 KB).

**TMDB (conoscenza del servizio, non riletta oggi).** API v3 con `api_key` in query oppure token v4 in `Authorization: Bearer` (i token v4 sono JWT che iniziano con «eyJ»);
`find/{imdb_id}?external_source=imdb_id`, `movie|tv/{id}?append_to_response=credits,videos,similar`, `person/{id}/combined_credits`, immagini su `image.tmdb.org/t/p/{size}`.
Condizione d'uso: mostrare l'attribuzione «This product uses the TMDB API but is not endorsed or certified by TMDB» (presente in scheda titolo e Informazioni).
**TheTVDB (dalla specifica letta):** v4 con login (`/login`) che restituisce un token; richiede chiave del progetto e, per alcune chiavi, un PIN di abbonamento. **Integrato** (`TvdbClient`, lib/core/metadata/tvdb_client.dart) per tradurre titoli e trame degli episodi: `POST /login` con `apikey` (e `pin` facoltativo) → `data.token`, token tenuto solo in memoria e rinnovato una volta su 401; `GET /search/remoteid/{imdb}` → id serie; `GET /series/{id}/episodes/default/{lingua ISO 639-2}?page=N`. I percorsi seguono la specifica letta e il client Swift del repository; ogni risposta inattesa vale «nessun dato extra».

**Implementazione.** `TmdbClient` (lib/core/metadata): chiave dall'archivio sicuro a ogni chiamata, mai nei log; ricerca per IMDb, dettagli con cast/trailer/produzione/saga, filmografia, id IMDb di un titolo.
Lingua dei dettagli configurabile (italiano di default). Nessuna chiave è inclusa nell'app.

**Verificato.** Parsing e intestazioni con server finto (test). **Non verificato** con la rete TMDB reale e con quote/limiti del servizio.
