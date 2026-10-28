# TorBox

**Fonti**
- `docs/research/torbox-api.md` del repository (ricavato da SDK ufficiali TorBox e da client di terzi aggiornati a ottobre 2026; etichette [V]/[C]/[I]/[M] nel documento originale).
- Probe delle API pubbliche: `docs/research/api-probe-2026-10-20.md`.
- https://api.torbox.app/openapi.json — **non raggiungibile** dall'ambiente il 2026-10-28: la verifica «contro la documentazione ufficiale corrente» richiesta dal prompt **non è stata possibile**; resta un punto aperto.

**Contratto usato** (base `https://api.torbox.app/v1/api`):
- `Authorization: Bearer <chiave>` (eccezione: `requestdl` vuole la chiave nel parametro `token`).
- `POST torrents/checkcached?format=list` con `{"hashes":[…]}`, **al massimo 100 hash per richiesta** (pratica osservata nei client); un hash assente = non in cache, mai un errore.
- `POST torrents/createtorrent` (form: `magnet`, `allow_zip=false`, `add_only_if_cached=true`): HTTP 409 = non in cache, nessun download parte. Il parametro `add_only_if_cached` è usato dalla versione iOS di Aether e documentato come «letto in sorgenti di terzi»: **non confermato dall'OpenAPI ufficiale**.
- `GET torrents/mylist?id=…&bypass_cache=true` (attesa a intervalli di 3 s, massimo 90 s per contenuti in cache) → `download_present && download_finished`, poi `GET torrents/requestdl?token=…&torrent_id=…&file_id=…` → URL https.
- Errori: 401/403 o `AUTH_ERROR` = chiave rifiutata; 429 = limite; `PLAN_RESTRICTED_FEATURE`; corpi HTML/testo dei gateway tollerati.

**Regole di sicurezza/etica (dalla documentazione letta).** Aether non cancella, non «ripara» né riaccoda elementi dell'utente; non avvia mai un download senza conferma esplicita; non salva l'URL CDN oltre la sessione.
I termini di servizio di TorBox **non sono stati letti** (pagina non accessibile): l'uso è limitato a ciò che l'utente chiede con la propria chiave.

**Implementazione.** `TorBoxClient`, `DebridResolver` (lib/core/debrid), `PlayPlanner`/`play_flow` per la conferma. **Verificato** con server finti (test); **mai provato contro TorBox reale**.
