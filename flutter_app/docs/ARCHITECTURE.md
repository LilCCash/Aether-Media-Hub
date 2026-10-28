# Architettura (2026-10-28)

```
lib/
  core/            Dart puro (nessun import Flutter tranne mood_color)
    model/           manifest, meta, stream (lettura tollerante)
    addons/          NetworkPolicy+AddonUrl, AddonClient, AddonRepository
    streams/         StreamAnalyzer, StreamRanker
    subtitles/       SubtitleParser (SRT/VTT/ASS-testo), SubtitleLoader
    debrid/          TorBoxClient, DebridResolver
    metadata/        TmdbClient
    util/            lenient, AppLog (oscura i segreti), mood_color
  data/            stores (KeyValue/Secret), settings, library_repository, backup
  app/             services (AppServices), providers (Riverpod), router, app (tema), mood, version
  design/          tokens, glass (GlassSurface/Button/Backdrop), widgets
  features/        home, discover, search, library, detail (+picker sorgenti), play (planner/flow), player, downloads, addons, settings, onboarding, shell
```
Regole di dipendenza: `core` non importa nulla sopra di sé; `features` parlano con `app/providers`; i widget non fanno rete direttamente (tranne il lancio di URL esterni).

**Flusso «guarda»**: scheda titolo → `StreamPickerSheet` (`streamsProvider` interroga in parallelo gli addon, `StreamRanker` ordina, `TorBoxClient.checkCached` marca i torrent) →
`playStream` (diretto | TorBox con `DebridResolver` e conferma prima di scaricare | esterno) → `PlayPlanner.buildArgs` → `PlayerScreen` (`PlayerSession` + `MediaKitEngine`).
**Persistenza**: JSON versionato in SharedPreferences (impostazioni, libreria, elenco addon senza indirizzi, download); segreti in archivio sicuro.
**Cancellazione e cicli di vita**: i provider legati a una schermata annullano le richieste in `ref.onDispose`; il player salva il progresso ogni 5 s, in pausa, in uscita e quando l'app va in background; i widget controllano `mounted` dopo ogni attesa.
**Stati**: caricamento (scheletri), vuoto (`EmptyState` con azione), errore (`ErrorState` con «Riprova»), successo — in ogni elenco di rete.

## Aggiunte della parità con iOS (2026-10-29)
- `lib/core/metadata/` — `service_http.dart` (HTTP comune dei servizi opzionali: timeout fissi, nessuna eccezione per gli stati HTTP, errori di rete senza indirizzo), `fanart_client.dart`, `mdblist_client.dart`, `tvdb_client.dart`.
- `lib/core/segments/skip_segments.dart` — IntroDB, finestra del pulsante «Salta intro», memoria delle risposte.
- `lib/core/debrid/` — `debrid_provider.dart` (interfaccia comune), `DebridResolver` (TorBox) e `RealDebridClient` implementano `DebridProvider`; `AppServices.activeDebrid` sceglie il servizio preferito che ha una chiave.
- `lib/core/streams/badge_pack*.dart` — badge importati da un link (formato Nuvio/Fusion), applicati alle sorgenti.
- `lib/core/catalog/result_filters.dart` — filtri tipo/genere/decennio, usati da Cerca e dalla Libreria.
- `lib/core/casting/upnp.dart` + `features/player/cast_sheet.dart` — DLNA «Trasmetti sulla TV» (Android).
- `lib/features/theater/` — `theater_prefs.dart` (dentro `AppSettings`), `theater_sound.dart` (suono generato), `theater_more.dart` (pagina «Altro»).
- `lib/app/orientation.dart` — orientamento e barre di sistema che la schermata sotto vuole, restituiti dal player alla chiusura.
- `lib/design/palettes.dart` — palette e caratteri dei titoli.
