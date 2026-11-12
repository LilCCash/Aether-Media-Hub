# Aether Android TV — parità con iOS

Fonte: `aether-swift-features` (app iOS 2.1: 143 file app + 130 file AetherCore, ~67k righe Swift), letta per aree; riferimento
secondario: `feature/aether-android-tv-addon-cancellation-fix` (Android TV 1.2.0-beta.1, ~11k righe Kotlin, 2 moduli `core`/`app`).

Stati: ☐ da fare · 🟡 fatto, da provare su TV · ✅ fatto e testato · 🔁 alternativa Android · ⛔ limite documentato.
Classi: E essenziale · I importante · S secondaria · P specifica di piattaforma · O personalizzazione opzionale.

| # | Area / funzione (dove su iOS) | Cl. | Android | Stato |
|---|---|---|---|---|
| **Addon e protocollo** | | | | |
| 1 | Installazione da URL / stremio:// / link, anteprima manifest, avvisi (rete locale, sconosciuto) — `Addons/AddonRegistry`, `AddonsView` | E | core `AddonRegistry` + schermata Addon | 🟡 |
| 2 | Manifest: risorse, tipi, cataloghi, extra (search, genre, skip), behaviorHints, config — `Models/Manifest` | E | core modelli kotlinx.serialization, parsing tollerante (`Lenient`) | ✅ |
| 3 | Catalog / meta / stream / subtitles, paginazione `skip`, cache risposte, timeout — `AddonClient`, `RequestPlanner`, `ResponseCache` | E | core `AddonClient` OkHttp + coroutines, cache | ✅ |
| 4 | Richieste parallele limitate e annullabili; stato di salute degli addon senza ricaricare i cataloghi (fix branch di riferimento) — `ConcurrencyLimiter`, `AddonService` | E | `Semaphore` + `supervisorScope`, cancellazione strutturata | ✅ |
| 5 | Ordine, abilita/disabilita, rimozione, aggiornamento manifest, addon consigliati (Cinemeta, OpenSubtitles v3) — `AddonsView`, `KnownAddons` | E | schermata Addon | 🟡 |
| 6 | Instradamento debrid per addon (Entrambi/TorBox/Real-Debrid), riscrittura Torrentio/Comet — `AddonDebridRouting` | I | core `AddonDebridRouting` 1:1 (scope per addon, riscrittura Torrentio/Comet, filtro sorgenti non pronte), chip «Debrid» sull'addon e dal telefono | ✅ |
| **Home** | | | | |
| 7 | Layout Classica (In evidenza: scheda o schermo intero, scorrimento automatico, intervallo) | E | Home TV con titoli in evidenza (scorrimento automatico, disattivabili) | 🟡 |
| 8 | Layout Vetrina (nome, foto, saluto, ricerca, categorie personalizzabili) — `GlassHome` | O | solo il saluto con nome; il layout «Vetrina» a tessere vetro è pensato per il touch e non è stato portato | ⛔ |
| 9 | Sezioni ordinabili/nascondibili con stile e dimensione schede: Continua, Prossimi episodi, Universe, Scelti per te, Watchlist, Cataloghi — `HomeSectionConfig` | E | ordine e visibilità di tutte le sezioni (Continua, Prossimo episodio, ogni catalogo) in «Personalizza la Home»; stile/dimensione per sezione ⛔, dimensione locandine globale | 🟡 |
| 10 | Saluto con nome — `Greeting` | O | 🟡 |
| **Scopri** | | | | |
| 11 | Tipi da addon, ordine/visibilità tipi, cataloghi per tipo, filtri genere/anno, griglia paginata — `DiscoverLayout`, `CatalogPager`, `ResultFilters` | E | tipi, cataloghi, filtro genere, griglia paginata | 🟡 |
| 12 | Scoperta cinematografica, Calendario uscite con promemoria, «Per te» (AI) — `DiscoveryViews`, `ReleaseCalendar` | S | non portato: Scoperta, Calendario uscite e «Per te» | ☐ |
| 13 | Universe (mappa, progresso, prossimo titolo) — `Universe/*` | S | Universe non portato | ☐ |
| **Cerca** | | | | |
| 14 | Ricerca su tutti gli addon con progresso, filtri tipo/genere/ordinamento, persone, cronologia — `SearchService`, `SearchView` | E | Cerca TV con tastiera TV, debounce, annullamento | 🟡 |
| 15 | Ricerca avanzata (intenti naturali, AI facoltativa) — `AdvancedSearchService`, `NaturalQueryParser` | S | ricerca avanzata (intenti naturali) non portata; nessuna AI | ☐ |
| **Scheda titolo** | | | | |
| 16 | Locandina, sfondo, logo (fanart), voti (IMDb, Metacritic, RT, MDBList), generi, durata, trama, cast/regia con foto, trailer, correlati, dettagli produzione — `TitlePageSections`, `MetadataEnricher`, `TMDBClient`, `TVDBClient`, `FanartClient`, `MDBListClient` | E | TMDB/TVDB, cast con foto, trailer, simili, produzione; voti MDBList (IMDb, RT, Metacritic…); logo fanart con chiave personale | 🟡 |
| 17 | Serie: stagioni, episodi con trama/immagine/visto, segna stagione vista, prossimo episodio — `NextEpisodeResolver` | E | 🟡 |
| 18 | Filmografia persona, premi (Wikidata) — `PersonFilmographyView`, `WikidataAwards` | S | 🟡 |
| 19 | «Dove eravamo rimasti?» (Apple Intelligence) | P | ⛔ nessun modello locale equivalente garantito; riassunto non generato | ⛔ |
| 20 | Artwork: scelta locandina/sfondo/logo — `ArtworkViews`, `PosterPicker` | O | ☐ |
| **Sorgenti e riproduzione** | | | | |
| 21 | Lista sorgenti: analisi (qualità, codec, HDR, audio, lingua, dimensione, formato), punteggio 0–100 con motivi, ordinamento, filtro, badge personalizzati, sorgente consigliata — `StreamAnalyzer`, `SourceRating`, `StreamSelector`, `StreamDisplaySettings` | E | analisi, punteggio 0–100 con motivi (`SourceRating`, anche in base a decoder e HDR della TV), ordinamento, filtro per addon, consigliata | ✅ |
| 22 | Player: play/pausa, ricerca con anteprima, salti ±, tracce audio, sottotitoli (addon, incorporati, file), stile e ritardo sottotitoli, doppi sottotitoli, velocità, info tecniche «In tempo reale», ripresa, prossimo episodio con conto alla rovescia, salta intro/riassunto (IntroDB), timer, blocco — `Player/*` | E | Media3: tracce audio, sottotitoli addon/incorporati con stile e ritardo, velocità, ripresa, prossimo episodio, IntroDB, timer; doppi sottotitoli ⛔ | 🟡 |
| 23 | Motori AVPlayer/MPV, conversione MKV per AVPlayer, remux — `Remux/*`, `PlaybackPlanner` | P | 🔁 ExoPlayer legge MKV/HEVC/AV1 nativamente; decoder audio software per AC3/EAC3/DTS dove manca il passthrough | 🔁 |
| 24 | Rilevamento capacità (HDR10/DV/HEVC/AV1) e fallback — `DeviceVideoCapabilities` | E | `DeviceCapabilities`: decoder da `MediaCodecList`, HDR da `Display.HdrCapabilities`; usati nel punteggio, visibili in Impostazioni ▸ Informazioni | ✅ |
| 25 | PiP, audio in background | P | Picture-in-Picture con il tasto Home durante un video (dove la TV lo supporta) | 🟡 |
| 26 | AirPlay / Google Cast / DLNA, ponte, «Guarda insieme» | P | ⛔ la TV è il ricevitore; non trasmette | ⛔ |
| 27 | Apertura cinematografica, titoli di coda in scena, schermata di pausa | O | ☐ |
| **Debrid** | | | | |
| 28 | TorBox: chiave, cache, aggiunta torrent, file, archivi ZIP/RAR, link, cloud — `TorBoxClient`, `ZipArchive`, `RarArchive` | E | chiave, cache, torrent, scelta file, link; archivi ZIP/RAR e cloud ⛔ (segnalati, non aperti) | 🟡 |
| 29 | Real-Debrid: OAuth device code, disponibilità solo reale, link — `RealDebridClient`, `RealDebridServiceSections` | E | token API privato (inseribile dal telefono); il device code OAuth non è usato perché l'app iOS usa lo stesso token; nessuna disponibilità finta | 🟡 |
| 30 | Selezione provider e filtro sorgenti per provider — `DebridResolver` | E | ✅ |
| **Libreria e dati** | | | | |
| 31 | Watchlist, preferiti, visti, abbandonati, collezioni, cronologia, continua a guardare, progresso — `LibraryStore`, `Collections` | E | watchlist, preferiti, visti, cronologia, continua; collezioni e abbandonati ⛔ | 🟡 |
| 32 | Backup/ripristino compatibile iOS (unisci/sostituisci) — `Backup` | E | stesso formato, unisci/sostituisci, chiavi di tutti i servizi | ✅ |
| 33 | Diario, statistiche, «Il mio universo del cinema», confronto voti, gioco dei gusti — `Diary`, `StatsView`, `TasteGame` | S | ☐ |
| 34 | Trakt: collegamento (device code), sincronizzazione visti/watchlist/progresso — `Trakt/*` | I | device code con QR, sincronizzazione watchlist/visti nei due sensi, scrobble dal player, cataloghi e liste | 🟡 |
| 35 | Sincronizzazione tramite cartella/iCloud — `ContentSync`, `FolderSyncService` | P | backup e ripristino dal telefono | 🔁 |
| **Download** | | | | |
| 36 | Download episodi/film, stagioni intere, pacchetti, concorrenza, avanzamento, annulla, riprendi, sottotitoli salvati, spazio — `DownloadManager`, `Downloads` | E | WorkManager in primo piano, ripresa con Range, pausa, elimina, controllo spazio, riproduzione offline; stagioni intere e sottotitoli salvati ⛔ | 🟡 |
| **Live TV** | | | | |
| 37 | Playlist M3U, cataloghi tv degli addon, preferiti, guida TV XMLTV (sotto i canali / griglia) — `LiveTV`, `TVGuide` | I | 🟡 |
| **Impostazioni** | | | | |
| 38 | Aspetto: layout, stili pronti, tema, accento, sfondo, schede, angoli, carattere, animazioni, effetti — `AppearanceView` | I | sottoinsieme sensato per TV | 🟡 |
| 39 | Riproduzione: lingue audio/sottotitoli, stile sottotitoli, qualità massima, ordinamento, salti, ripresa, prossimo episodio, salta intro — `PlaybackSettings` | E | 🟡 |
| 40 | Contenuti: lingua, adulti, talk show, cataloghi, tipi di Scopri, moduli scheda, voti — `ContentSettings` | I | 🟡 |
| 41 | Servizi e chiavi: TMDB, TVDB, fanart, MDBList, OpenSubtitles, TorBox, Real-Debrid, Trakt | E | TMDB, TVDB, fanart, MDBList, TorBox, Real-Debrid, Trakt; OpenSubtitles è un addon | ✅ |
| 42 | Archiviazione, cache, privacy, diagnostica/registro | I | 🟡 |
| **Configurazione da telefono (QR)** | | | | |
| 43 | Riferimento Android: server LAN NanoHTTPD con token, form per addon, chiavi TMDB/TVDB/TorBox, ripristino backup | E | porta e token (256 bit) casuali, approvazione del telefono sulla TV, un solo telefono, scadenza 10 min (max 30), chiusura dopo token errati, controllo Origin, nessuna chiave mostrata; testato | ✅ |
| **Profilo** | | | | |
| 44 | Avatar, nome, generi preferiti — `Profile` | S | 🟡 |
| **Specifiche iOS escluse** | Siri/Comandi, widget, Spotlight, icone alternative, Theater Mode (escluso dal prompt) | P | ⛔ (canali della schermata Home di Android TV non realizzati) | ⛔ |


## Riepilogo (fine lavoro)

- ✅ 10 · 🟡 23 (fatto, compilato e coperto dove possibile da test, da provare su una TV vera) · 🔁 2 · ⛔ 4 · ☐ 6 (Scoperta/Calendario, Universe, ricerca avanzata, artwork, apertura cinematografica, diario/statistiche).
- Nessuna funzione segnata come fatta è un pulsante vuoto: dove una parte manca è scritta nella colonna Android.
- Non verificato su hardware: questa build è stata compilata e testata (unit test core e app) senza un dispositivo Android TV.
