# Aether Android TV — parità con iOS

Fonte: `aether-swift-features` (app iOS 2.1: 143 file app + 130 file AetherCore, ~67k righe Swift), letta per aree; riferimento
secondario: `feature/aether-android-tv-addon-cancellation-fix` (Android TV 1.2.0-beta.1, ~11k righe Kotlin, 2 moduli `core`/`app`).

Stati: ☐ da fare · 🟡 fatto, da provare su TV · ✅ fatto e testato · 🔁 alternativa Android · ⛔ limite documentato.
Classi: E essenziale · I importante · S secondaria · P specifica di piattaforma · O personalizzazione opzionale.

| # | Area / funzione (dove su iOS) | Cl. | Android | Stato |
|---|---|---|---|---|
| **Addon e protocollo** | | | | |
| 1 | Installazione da URL / stremio:// / link, anteprima manifest, avvisi (rete locale, sconosciuto) — `Addons/AddonRegistry`, `AddonsView` | E | core `AddonRegistry` + schermata Addon | ☐ |
| 2 | Manifest: risorse, tipi, cataloghi, extra (search, genre, skip), behaviorHints, config — `Models/Manifest` | E | core modelli kotlinx.serialization, parsing tollerante (`Lenient`) | ☐ |
| 3 | Catalog / meta / stream / subtitles, paginazione `skip`, cache risposte, timeout — `AddonClient`, `RequestPlanner`, `ResponseCache` | E | core `AddonClient` OkHttp + coroutines, cache | ☐ |
| 4 | Richieste parallele limitate e annullabili; stato di salute degli addon senza ricaricare i cataloghi (fix branch di riferimento) — `ConcurrencyLimiter`, `AddonService` | E | `Semaphore` + `supervisorScope`, cancellazione strutturata | ☐ |
| 5 | Ordine, abilita/disabilita, rimozione, aggiornamento manifest, addon consigliati (Cinemeta, OpenSubtitles v3) — `AddonsView`, `KnownAddons` | E | schermata Addon | ☐ |
| 6 | Instradamento debrid per addon (Entrambi/TorBox/Real-Debrid), riscrittura Torrentio/Comet — `AddonDebridRouting` | I | core porting 1:1 | ☐ |
| **Home** | | | | |
| 7 | Layout Classica (In evidenza: scheda o schermo intero, scorrimento automatico, intervallo) | E | Home TV con hero | ☐ |
| 8 | Layout Vetrina (nome, foto, saluto, ricerca, categorie personalizzabili) — `GlassHome` | O | variante Home TV | ☐ |
| 9 | Sezioni ordinabili/nascondibili con stile e dimensione schede: Continua, Prossimi episodi, Universe, Scelti per te, Watchlist, Cataloghi — `HomeSectionConfig` | E | stesso modello, editor in Impostazioni | ☐ |
| 10 | Saluto con nome — `Greeting` | O | | ☐ |
| **Scopri** | | | | |
| 11 | Tipi da addon, ordine/visibilità tipi, cataloghi per tipo, filtri genere/anno, griglia paginata — `DiscoverLayout`, `CatalogPager`, `ResultFilters` | E | Scopri TV | ☐ |
| 12 | Scoperta cinematografica, Calendario uscite con promemoria, «Per te» (AI) — `DiscoveryViews`, `ReleaseCalendar` | S | Scoperta e Calendario 🔁; AI secondo disponibilità | ☐ |
| 13 | Universe (mappa, progresso, prossimo titolo) — `Universe/*` | S | lista universi + progresso; mappa semplificata per telecomando 🔁 | ☐ |
| **Cerca** | | | | |
| 14 | Ricerca su tutti gli addon con progresso, filtri tipo/genere/ordinamento, persone, cronologia — `SearchService`, `SearchView` | E | Cerca TV con tastiera TV, debounce, annullamento | ☐ |
| 15 | Ricerca avanzata (intenti naturali, AI facoltativa) — `AdvancedSearchService`, `NaturalQueryParser` | S | parser naturale in core; AI ⛔ se richiede Apple Intelligence | ☐ |
| **Scheda titolo** | | | | |
| 16 | Locandina, sfondo, logo (fanart), voti (IMDb, Metacritic, RT, MDBList), generi, durata, trama, cast/regia con foto, trailer, correlati, dettagli produzione — `TitlePageSections`, `MetadataEnricher`, `TMDBClient`, `TVDBClient`, `FanartClient`, `MDBListClient` | E | scheda TV con sezioni | ☐ |
| 17 | Serie: stagioni, episodi con trama/immagine/visto, segna stagione vista, prossimo episodio — `NextEpisodeResolver` | E | | ☐ |
| 18 | Filmografia persona, premi (Wikidata) — `PersonFilmographyView`, `WikidataAwards` | S | | ☐ |
| 19 | «Dove eravamo rimasti?» (Apple Intelligence) | P | ⛔ nessun modello locale equivalente garantito; riassunto non generato | ⛔ |
| 20 | Artwork: scelta locandina/sfondo/logo — `ArtworkViews`, `PosterPicker` | O | | ☐ |
| **Sorgenti e riproduzione** | | | | |
| 21 | Lista sorgenti: analisi (qualità, codec, HDR, audio, lingua, dimensione, formato), punteggio 0–100 con motivi, ordinamento, filtro, badge personalizzati, sorgente consigliata — `StreamAnalyzer`, `SourceRating`, `StreamSelector`, `StreamDisplaySettings` | E | core porting; lista sorgenti TV | ☐ |
| 22 | Player: play/pausa, ricerca con anteprima, salti ±, tracce audio, sottotitoli (addon, incorporati, file), stile e ritardo sottotitoli, doppi sottotitoli, velocità, info tecniche «In tempo reale», ripresa, prossimo episodio con conto alla rovescia, salta intro/riassunto (IntroDB), timer, blocco — `Player/*` | E | Media3 ExoPlayer, UI TV | ☐ |
| 23 | Motori AVPlayer/MPV, conversione MKV per AVPlayer, remux — `Remux/*`, `PlaybackPlanner` | P | 🔁 ExoPlayer legge MKV/HEVC/AV1 nativamente; decoder audio software per AC3/EAC3/DTS dove manca il passthrough | ☐ |
| 24 | Rilevamento capacità (HDR10/DV/HEVC/AV1) e fallback — `DeviceVideoCapabilities` | E | `MediaCodecList`, `Display.HdrCapabilities` | ☐ |
| 25 | PiP, audio in background | P | 🔁 PiP su Android TV dove supportato | ☐ |
| 26 | AirPlay / Google Cast / DLNA, ponte, «Guarda insieme» | P | ⛔ la TV è il ricevitore; non trasmette | ⛔ |
| 27 | Apertura cinematografica, titoli di coda in scena, schermata di pausa | O | | ☐ |
| **Debrid** | | | | |
| 28 | TorBox: chiave, cache, aggiunta torrent, file, archivi ZIP/RAR, link, cloud — `TorBoxClient`, `ZipArchive`, `RarArchive` | E | core porting + riferimento Android | ☐ |
| 29 | Real-Debrid: OAuth device code, disponibilità solo reale, link — `RealDebridClient`, `RealDebridServiceSections` | E | device code (adatto alla TV) | ☐ |
| 30 | Selezione provider e filtro sorgenti per provider — `DebridResolver` | E | | ☐ |
| **Libreria e dati** | | | | |
| 31 | Watchlist, preferiti, visti, abbandonati, collezioni, cronologia, continua a guardare, progresso — `LibraryStore`, `Collections` | E | JSON compatibile iOS | ☐ |
| 32 | Backup/ripristino compatibile iOS (unisci/sostituisci) — `Backup` | E | stesso formato | ☐ |
| 33 | Diario, statistiche, «Il mio universo del cinema», confronto voti, gioco dei gusti — `Diary`, `StatsView`, `TasteGame` | S | | ☐ |
| 34 | Trakt: collegamento (device code), sincronizzazione visti/watchlist/progresso — `Trakt/*` | I | device code | ☐ |
| 35 | Sincronizzazione tramite cartella/iCloud — `ContentSync`, `FolderSyncService` | P | 🔁 backup via QR/telefono | ☐ |
| **Download** | | | | |
| 36 | Download episodi/film, stagioni intere, pacchetti, concorrenza, avanzamento, annulla, riprendi, sottotitoli salvati, spazio — `DownloadManager`, `Downloads` | E | WorkManager + servizio in primo piano, storage app | ☐ |
| **Live TV** | | | | |
| 37 | Playlist M3U, cataloghi tv degli addon, preferiti, guida TV XMLTV (sotto i canali / griglia) — `LiveTV`, `TVGuide` | I | | ☐ |
| **Impostazioni** | | | | |
| 38 | Aspetto: layout, stili pronti, tema, accento, sfondo, schede, angoli, carattere, animazioni, effetti — `AppearanceView` | I | sottoinsieme sensato per TV | ☐ |
| 39 | Riproduzione: lingue audio/sottotitoli, stile sottotitoli, qualità massima, ordinamento, salti, ripresa, prossimo episodio, salta intro — `PlaybackSettings` | E | | ☐ |
| 40 | Contenuti: lingua, adulti, talk show, cataloghi, tipi di Scopri, moduli scheda, voti — `ContentSettings` | I | | ☐ |
| 41 | Servizi e chiavi: TMDB, TVDB, fanart, MDBList, OpenSubtitles, TorBox, Real-Debrid, Trakt | E | + configurazione da telefono | ☐ |
| 42 | Archiviazione, cache, privacy, diagnostica/registro | I | | ☐ |
| **Configurazione da telefono (QR)** | | | | |
| 43 | Riferimento Android: server LAN NanoHTTPD con token, form per addon, chiavi TMDB/TVDB/TorBox, ripristino backup | E | sessioni brevi, conferma sulla TV, chiave in frammento URL, tutte le chiavi e gli addon | ☐ |
| **Profilo** | | | | |
| 44 | Avatar, nome, generi preferiti — `Profile` | S | | ☐ |
| **Specifiche iOS escluse** | Siri/Comandi, widget, Spotlight, icone alternative, Theater Mode (escluso dal prompt) | P | ⛔ / canali e «Continua a guardare» della schermata Home di Android TV 🔁 valutati in fase 6 | ⛔ |
