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
| | Link `stremio://`, `aether://` | ✅ | ✅ | **PARZIALE** | parser sì; **nessun gestore nativo di deep link** |
| | QR code per URL lunghi / pagina del telefono | ⛔ | ✅ | **NO** | fuori portata; incolla dagli appunti |
| | Pagina `/configure` dell'addon | ✅ | 🟡 | **FATTO\*** | apre il browser |
| Home | Righe dai cataloghi, «Continua a guardare», titolo in evidenza | ✅ | ✅ | **FATTO\*** | `ui_test` (righe, hero) |
| | Sezioni nascoste/riordinabili, nomi cataloghi | ✅ | 🟡 | **FATTO** | Impostazioni ▸ Cataloghi |
| | Saluto, temi, sfondi, cornici, caratteri (personalizzazione 1.1) | ✅ | ⛔ | **PARZIALE** | accento, vetro, Cinematic, AMOLED sì; palette/cornici/caratteri no |
| Scopri | Tipi, cataloghi, genere, paginazione `skip` | ✅ | 🟦 | **FATTO\*** | `discover_screen` |
| Cerca | Ricerca su tutti i cataloghi, risultati progressivi, recenti | ✅ | ✅ | **FATTO** | `searchProvider`, `ui_test` |
| | Ricerca locale in libreria; filtri anno/genere | ✅ | 🟦 | **NO** | |
| Scheda titolo | Sfondo, trama, generi, cast, stagioni/episodi, visto/progressi | ✅ | 🟦 | **FATTO\*** | `ui_test` |
| | Preferiti, watchlist, segna visto | ✅ | ✅ | **FATTO** | `LibraryRepository` |
| | TMDB: cast con foto, produzione, budget, trailer, saga, filmografia | ✅ | ✅ | **FATTO\*** | `TmdbClient` (server finto); mai contro TMDB reale |
| | TheTVDB | ✅ | ✅ | **NO** | solo TMDB |
| | MDBList (voti), logo fanart.tv, badge importati | ✅ (1.4/1.5) | ⛔ | **NO** | non portati |
| Sorgenti | Analisi nome (qualità, codec, HDR, audio, lingua, dimensione, formato), ordine, scelta | ✅ | ✅ | **FATTO** | `StreamAnalyzer`/`StreamRanker` |
| | Filtro per addon, badge, elenco progressivo | ✅ | ✅ | **FATTO\*** | `ui_test` |
| TorBox | Chiave, cache, torrent→link, conferma download, progresso | ✅ | ✅ | **FATTO\*** | `TorBoxClient`/`DebridResolver` con server finto; **mai TorBox reale** |
| | Real-Debrid | ✅ | ⛔ | **NO** | |
| Player | Link diretti, MKV, tracce, sottotitoli | ✅ (AVPlayer+MPV) | 🟦 | **FATTO\*** | `PlayerSession` provata; motore non eseguito su telefono |
| | Controlli: play/pausa, ±10 s, barra, velocità, formato, blocco, auto-hide, doppio tocco | ✅ | ✅ | **FATTO\*** | `ui_test` player |
| | Ripresa, cronologia, soglia «visto» | ✅ | ✅ | **FATTO** | `player_session_test` |
| | Episodio successivo con conto alla rovescia | ✅ | ✅ | **FATTO** | `play_planner_test` |
| | Sorgente alternativa mantenendo la posizione | ✅ | ✅ | **FATTO** | test |
| | Sottotitoli: incorporati, addon, sincronia ±, pulizia non udenti | ✅ | ✅ | **FATTO** | test; ASS solo testo |
| | Orientamento orizzontale del player | ✅ (contenitore UIKit) | — | **FATTO\*** | da provare su iPhone |
| | PiP | ✅ | ⛔ | **PARZIALE** | Android sì (non provato); iOS no (libmpv) |
| | HDR / Dolby Vision | ✅ (AVPlayer) | 🟦 | **NO (non verificato)** | nessuna conversione nostra |
| | AirPlay, Google Cast, DLNA, ponte e remux | ✅ | ⛔ | **NO** | LIMITATIONS |
| | Salta intro (IntroDB) | ✅ | ✅ | **NO** | |
| | Gesti luminosità/volume | ✅ | — | **NO** | doppio tocco e scorrimento orizzontale sì |
| Libreria | Continua, watchlist, preferiti, cronologia | ✅ | ✅ | **FATTO** | `ui_test` |
| Download | Link diretti, pausa/ripresa (Range), offline, stato dopo il riavvio | ✅ | ⛔ | **FATTO** | `download_test`, `play_planner_test` |
| Impostazioni | Riproduzione, aspetto, contenuti, servizi, dati, diagnostica, licenze | ✅ | ✅ | **FATTO** | `ui_test` (apertura di ogni pagina) |
| | Backup/ripristino (libreria, impostazioni, opzionalmente chiavi e addon) | ✅ | ✅ | **FATTO** | `backup_test`; via appunti, non file |
| | Cinematic UI, AMOLED | ✅ | ⛔ | **FATTO\*** | |
| Diagnostica | Registro con oscuramento dei segreti | ✅ | ⛔ | **FATTO** | `domain_test` |
| | **Player di prova offline** | — | — | **FATTO\*** | Impostazioni ▸ Diagnostica; assets inclusi |
| Theater Mode | Interfaccia cinema a schermo intero in orizzontale | ✅ | ➖ | **PARZIALE** | versione snella: binario laterale, titolo in evidenza (primo tocco) con «Guarda», righe 16:9 dei cataloghi, sipario d'ingresso; Scopri/Cerca/Libreria sono le schermate normali in orizzontale. **Senza** musica d'introduzione, proiettore, palette e impostazioni dedicate dell'originale iOS |

**Lettura onesta.** La parte «dati e rete» (addon, cataloghi, sorgenti, TorBox, TMDB, sottotitoli, libreria, download, backup) è implementata e testata in Dart con server finti.
La parte «schermo e media» (player reale, PiP, HDR, orientamento, prestazioni) è **compilata** ma **non eseguita** su dispositivi: finché non lo è, non va considerata verificata.
