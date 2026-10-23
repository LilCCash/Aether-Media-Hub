# Aether per Android TV — matrice di parità con la versione per iPhone

Ricavata leggendo il codice di `Packages/AetherCore` e dell'app iOS (non le descrizioni). Gli stati dicono **solo ciò che è stato verificato**:

- ✅ **Implementato e provato da test automatici** (test del core in Kotlin, eseguiti in CI e in locale).
- 🟦 **Implementato, compilato in CI, non provato su una TV**: il codice della schermata o del player esiste e compila, ma nessuno l'ha visto girare (nessun emulatore né dispositivo a disposizione).
- 🟡 **Parziale**: c'è una parte, vedi la nota.
- ⛔ **Non implementato** (motivo indicato).
- ➖ **Esclusa di proposito** (Theater Mode).

| Area | Funzione su iPhone | Android TV | Stato |
|---|---|---|---|
| **Addon** | Protocollo Stremio: manifest, `catalog`, `meta`, `stream`, `subtitles`, `addon_catalog` | `core/addons`, `core/model` (parser tolleranti come quelli iOS) | ✅ |
| | Installazione da URL con anteprima, avvisi (non verificato, p2p, adulti, rete locale), duplicati | `AddonRegistry.preview/install`, schermata Addon | ✅ core · 🟦 UI |
| | Indirizzi degli addon (con chiavi) fuori dai file dei dati | `SecretStore` (Keystore AES-GCM su Android) | ✅ core · 🟦 Keystore |
| | Abilita/disabilita, ordine (priorità), rinomina, cataloghi nascosti, aggiorna manifest, rimuovi | `AddonRegistry` + schermata Addon | ✅ core · 🟦 UI |
| | Link `stremio://` e `aether://addon?url=` | `AddonUrl.installUrlFromDeepLink`, intent filter, conferma prima di installare | ✅ parser · 🟦 intent |
| | Pagina di configurazione dell'addon | apre `/configure` con il browser, se la TV ne ha uno | 🟡 (molte TV non hanno un browser: lo dice) |
| | Politica di rete: niente loopback, rete locale solo se abilitata, niente credenziali nell'URL | `NetworkPolicy` | ✅ (non controlla il DNS: manca la protezione dal DNS rebinding dell'iOS) |
| | Cache delle risposte con `cacheMaxAge`, uso del vecchio in caso di errore | `ResponseCache` + `AddonClient` | ✅ |
| **Home** | Righe dai cataloghi, «Continua a guardare», «Prossimo episodio», titolo in evidenza | `HomeScreen`, `HomeViewModel` | ✅ logica · 🟦 UI |
| | Sezioni nascoste/riordinabili, saluto personalizzato, temi/sfondi/cornici (personalizzazione grafica 1.1) | solo accento, dimensione locandine, animazioni, sezioni «Continua» e «Prossimo» on/off | 🟡 (la personalizzazione grafica ampia dell'iPhone non è portata) |
| **Scopri** | Tipi, cataloghi, filtro per genere, paginazione `skip` | `DiscoverScreen`, `DiscoverViewModel` | 🟦 |
| **Cerca** | Ricerca su tutti i cataloghi con `search`, risultati man mano, ordine, ricerche recenti, ricerca locale | `SearchService` (✅ test), `SearchScreen` | ✅ core · 🟦 UI |
| | Filtri per anno/genere nella ricerca | solo filtro per tipo (Tutto/Film/Serie) | 🟡 |
| **Dettagli** | Scheda con sfondo, trama, generi, cast, regia, stagioni ed episodi, visto/progressi | `DetailScreen` | 🟦 |
| | Preferiti, watchlist, segna come visto (titolo, episodio, stagione) | sì | ✅ core · 🟦 UI |
| | Trailer | apre YouTube con l'app della TV, se c'è | 🟡 |
| | Scheda ricca con TMDB/TheTVDB (cast con foto, produzioni, budget, titoli simili) | **non portata** | ⛔ (richiede le chiavi dell'utente e un lavoro a parte) |
| **Sorgenti** | Analisi dei nomi (qualità, codec, HDR, audio, lingua, dimensione, formato), ordine per addon o «migliori», scelta automatica con continuità della release | `StreamAnalyzer`, `StreamSelector`, `StreamsScreen` | ✅ core · 🟦 UI |
| | TorBox: chiave, controllo cache, torrent→link, download con conferma, scelta del file, progresso | `core/debrid`, `StreamsScreen` | ✅ core (con server finto) · 🟦 UI · ⛔ mai provato contro il vero TorBox |
| | Server di streaming esterno per i torrent | URL configurabile | ✅ costruzione dell'indirizzo · 🟦 resto |
| **Player** | Riproduzione di link diretti, HLS | Media3 / ExoPlayer | 🟦 |
| | MKV, WebM, TS, MP4; DASH | supportati da ExoPlayer; AVI/WMV/DivX **no** (la sorgente è segnata «non riproducibile» con il motivo) | 🟦 |
| | Motore MPV, conversione al volo degli MKV, ponte per Cast/AirPlay | **non portati**: su Android TV ExoPlayer legge già gli MKV | ⛔ (non necessari) |
| | Play/pausa, salti, barra, velocità, formato (adatta/riempi/allunga) | sì | 🟦 |
| | Audio e sottotitoli: tracce incluse nel file e sottotitoli degli addon | sì (i sottotitoli degli addon si aggiungono come traccia) | 🟦 |
| | Stile dei sottotitoli (dimensione, colore, sfondo, contorno, altezza) | sì | 🟦 |
| | Ripresa del punto, cronologia, soglia «visto» | sì | ✅ core · 🟦 player |
| | Episodio successivo automatico con conto alla rovescia, precedente/successivo | sì | 🟦 |
| | Salta intro / riassunto (IntroDB) | sì | ✅ client · 🟦 pulsante |
| | Errori spiegati, riprova, altra sorgente | sì | 🟦 |
| | Gesti sul video, luminosità, Picture in Picture, AirPlay, Google Cast, DLNA | **non applicabili/non portati** su una TV | ⛔ |
| | Hash dei sottotitoli calcolato sul dispositivo (OpenSubtitles) | usa solo hash/dimensione/nome dichiarati dall'addon | 🟡 |
| | Rimozione dei tag per non udenti dai sottotitoli | **non portata** (impostazione presente nel modello, non applicata) | ⛔ |
| **Libreria** | Continua, watchlist, preferiti, cronologia (rimuovi voce, cancella tutto) | `LibraryScreen` | ✅ core · 🟦 UI |
| | Download per vedere offline | **non portati** (Android TV non è pensato per scaricare; nessun download manager) | ⛔ |
| **Impostazioni** | Aspetto, riproduzione, contenuti/ricerca, rete, servizi (TorBox), privacy | `SettingsScreen` | 🟦 |
| | Backup/ripristino: stesso formato `app.aether.backup` dell'iPhone (libreria) | `BackupCodec` legge anche i backup dell'iPhone | ✅ |
| | Registro diagnostico (Avanzate ▸ Diagnostica) | **non portato** | ⛔ |
| | Chiavi TMDB/TheTVDB, easter egg, intro, personalizzazione Home | non portati | ⛔ |
| **Theater Mode** | Interfaccia a schermo intero in orizzontale | nessun pulsante, voce o impostazione | ➖ |
| **Navigazione TV** | — | D-pad, OK, Indietro, Play/Pausa, menu laterale che si espande, focus evidente (ingrandimento + bordo + ombra), ritorno sul poster dove eri | 🟦 (la logica dei tasti del player è nel codice; non provata con un telecomando) |
