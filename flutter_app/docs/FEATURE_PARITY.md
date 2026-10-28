# Parità funzionale iOS ↔ Android TV ↔ Flutter (2026-10-28)

Ricavata **leggendo i documenti e il codice** dei rami `main-secondary` (iOS, Swift) e `feature/aether-android-tv` (Kotlin; `android-tv/docs/PARITA.md`), non le descrizioni.
Stati originali: ✅ implementato e provato da test · 🟦 compilato/provato solo in CI o simulatore · 🟡 parziale · ⛔ assente.
Stato **Flutter** (colonna finale): **FATTO** = implementato e coperto da test automatici in Dart; **FATTO\*** = implementato ma **non eseguito su un telefono**; **PARZIALE**; **NO** (con motivo). I test sono quelli elencati in `TESTING.md`.

| Area | Funzione | iOS (originale) | Android TV (originale) | Flutter | Test / note |
|---|---|---|---|---|---|
| Addon | Manifest tollerante, catalog/meta/stream/subtitles | ✅ | ✅ | **FATTO** | `core_model_test`, `addon_client_test` |
| | Installazione da URL con anteprima, avvisi, duplicati | ✅ | ✅ | **FATTO** | stesso; avvisi p2p/adulti/http |
| | Abilita/disabilita, ordine/priorità, rinomina, cataloghi nascosti, aggiorna, rimuovi | ✅ | ✅ | **FATTO** | `AddonRepository`, schermata Addon |
| | Indirizzi addon fuori dai file di dati | Keychain | Keystore | **FATTO** | archivio sicuro; test: l'indirizzo non finisce nello store in chiaro |
| | Politica di rete (loopback, LAN, credenziali nell'URL) | ✅ (con anti-rebinding) | ✅ (senza DNS) | **FATTO** (senza controllo DNS) | `NetworkPolicy` |
| | Cache `cacheMaxAge` | ✅ | ✅ | **FATTO** | test di cache |
| | Link `stremio://`, `aether://` | ✅ | ✅ | **FATTO\*** | gestori nativi (Android intent-filter, iOS URL scheme) → pagina Addon con anteprima; il percorso è provato da test (`ui_test`), il gestore di sistema **non** su telefono |
| | QR code per URL lunghi / pagina del telefono | ⛔ | ✅ | **NO** | fuori portata; incolla dagli appunti |
| | Pagina `/configure` dell'addon | ✅ | 🟡 | **FATTO\*** | apre il browser |
| Home | Righe dai cataloghi, «Continua a guardare», titolo in evidenza | ✅ | ✅ | **FATTO\*** | `ui_test` (righe, hero) |
| | Sezioni nascoste/riordinabili, nomi cataloghi | ✅ | 🟡 | **FATTO** | Impostazioni ▸ Cataloghi |
| | Saluto, palette, carattere dei titoli (personalizzazione 1.1) | ✅ | ⛔ | **PARZIALE** | saluto, 8 palette, 3 caratteri di sistema; **non** cornici, stili degli angoli, layout delle card |
| Scopri | Tipi, cataloghi, genere, paginazione `skip` | ✅ | 🟦 | **FATTO\*** | `discover_screen` |
| Cerca | Ricerca su tutti i cataloghi, risultati progressivi, recenti | ✅ | ✅ | **FATTO** | `searchProvider`, `ui_test` |
| | Ricerca locale in libreria; filtri tipo/genere/decennio | ✅ | 🟦 | **FATTO** | `filters_test`; filtri anche nei risultati di Cerca |
| Scheda titolo | Sfondo, trama, generi, cast, stagioni/episodi, visto/progressi | ✅ | 🟦 | **FATTO\*** | `ui_test` |
| | Preferiti, watchlist, segna visto | ✅ | ✅ | **FATTO** | `LibraryRepository` |
| | TMDB: cast con foto, produzione, budget, trailer, saga, filmografia | ✅ | ✅ | **FATTO\*** | `TmdbClient` (server finto); mai contro TMDB reale |
| | TheTVDB (titoli e trame degli episodi tradotti) | ✅ | ✅ | **FATTO\*** | `TvdbClient` con server finto (login, nuovo login su 401, episodi); mai contro TheTVDB reale |
| | MDBList (voti), logo fanart.tv, badge importati | ✅ (1.4/1.5) | ⛔ | **FATTO\*** | `services_test`, `badge_pack_test` con server finti; formato badge «filters» Nuvio/Fusion e lista semplice; mai contro i servizi reali |
| Sorgenti | Analisi nome (qualità, codec, HDR, audio, lingua, dimensione, formato), ordine, scelta | ✅ | ✅ | **FATTO** | `StreamAnalyzer`/`StreamRanker` |
| | Filtro per addon, badge, elenco progressivo | ✅ | ✅ | **FATTO\*** | `ui_test` |
| TorBox | Chiave, cache, torrent→link, conferma download, progresso | ✅ | ✅ | **FATTO\*** | `TorBoxClient`/`DebridResolver` con server finto; **mai TorBox reale** |
| | Real-Debrid | ✅ | ⛔ | **FATTO\*** | `RealDebridClient` (server finto): nessuna sonda di cache (endpoint ritirato), conferma prima di aggiungere, link https; selettore del servizio preferito; mai contro Real-Debrid reale |
| Player | Link diretti, MKV, tracce, sottotitoli | ✅ (AVPlayer+MPV) | 🟦 | **FATTO\*** | `PlayerSession` provata; motore non eseguito su telefono |
| | Controlli: play/pausa, ±10 s, barra, velocità, formato, blocco, auto-hide, doppio tocco | ✅ | ✅ | **FATTO\*** | `ui_test` player |
| | Ripresa, cronologia, soglia «visto» | ✅ | ✅ | **FATTO** | `player_session_test` |
| | Episodio successivo con conto alla rovescia | ✅ | ✅ | **FATTO** | `play_planner_test` |
| | Sorgente alternativa mantenendo la posizione | ✅ | ✅ | **FATTO** | test |
| | Sottotitoli: incorporati, addon, sincronia ±, pulizia non udenti | ✅ | ✅ | **FATTO** | test; ASS solo testo |
| | Orientamento orizzontale del player | ✅ (contenitore UIKit) | — | **FATTO\*** | da provare su iPhone |
| | PiP | ✅ | ⛔ | **PARZIALE** | Android sì (non provato); iOS no (libmpv) |
| | HDR / Dolby Vision | ✅ (AVPlayer) | 🟦 | **NO (non verificato)** | nessuna conversione nostra |
| | AirPlay, Google Cast, ponte e remux | ✅ | ⛔ | **NO** | LIMITATIONS: AirPlay/Cast nativo e ponte/remux non portati |
| | **DLNA/UPnP «Trasmetti sulla TV»** | ✅ | ⛔ | **PARZIALE** | link http(s) alla TV (SOAP AVTransport), solo **Android** (la ricerca SSDP su iPhone richiede un permesso Apple); `upnp_test` con server finti; non provato su una TV reale |
| | Salta intro / riassunto (IntroDB) | ✅ | ✅ | **FATTO\*** | `services_test` (parsing, finestra del pulsante, cache); pulsante nel player non provato su telefono |
| | Gesti luminosità/volume | ✅ | — | **FATTO\*** | trascinamento verticale a sinistra (luminosità di sistema dell'app) e a destra (volume del *player*, non del sistema); non provato su telefono |
| Libreria | Continua, watchlist, preferiti, cronologia | ✅ | ✅ | **FATTO** | `ui_test` |
| Download | Link diretti, pausa/ripresa (Range), offline, stato dopo il riavvio | ✅ | ⛔ | **FATTO** | `download_test`, `play_planner_test` |
| Impostazioni | Riproduzione, aspetto, contenuti, servizi, dati, diagnostica, licenze | ✅ | ✅ | **FATTO** | `ui_test` (apertura di ogni pagina) |
| | Backup/ripristino (libreria, impostazioni, opzionalmente chiavi e addon) | ✅ | ✅ | **FATTO** | `backup_test`; via appunti, non file |
| | Cinematic UI, AMOLED | ✅ | ⛔ | **FATTO\*** | |
| Diagnostica | Registro con oscuramento dei segreti | ✅ | ⛔ | **FATTO** | `domain_test` |
| | **Player di prova offline** | — | — | **FATTO\*** | Impostazioni ▸ Diagnostica; assets inclusi |
| Theater Mode | Interfaccia cinema a schermo intero in orizzontale | ✅ | ➖ | **PARZIALE** | binario laterale scorrevole (con uscita sempre visibile), titolo in evidenza con «Guarda», righe 16:9 o verticali con titoli/dettagli, 5 palette, 3 sfondi, 3 dimensioni, fori della pellicola, introduzione con suono **generato dall'app**, pagina «Altro» (impostazioni, servizio debrid, collegamenti); il player restituisce l'orientamento orizzontale. **Senza** effetto proiettore, angoli/bordo/alone configurabili e stile dei titoli di riga |

**Lettura onesta.** La parte «dati e rete» (addon, cataloghi, sorgenti, TorBox, TMDB, sottotitoli, libreria, download, backup) è implementata e testata in Dart con server finti.
La parte «schermo e media» (player reale, PiP, HDR, orientamento, prestazioni) è **compilata** ma **non eseguita** su dispositivi: finché non lo è, non va considerata verificata.
