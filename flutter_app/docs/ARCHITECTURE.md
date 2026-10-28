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
