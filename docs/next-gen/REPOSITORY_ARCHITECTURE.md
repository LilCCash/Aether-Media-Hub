# Architettura del repository

407 file Swift nel branch (399 alla base + 8 nuovi). Due livelli:

- **`Packages/AetherCore`** (Swift package, nessuna dipendenza UI, testato su Linux e macOS): protocollo addon Stremio,
  modelli, rete con policy, cache, ricerca, libreria, metadati (TMDB/TVDB/Fanart/Wikidata), debrid (TorBox), Trakt,
  impostazioni, sottotitoli, relay HTTP per il cast, parte pura del remux, Universe, diario, Live TV.
- **`App/Aether`** (SwiftUI, iOS 17+, XcodeGen): schermate, player (AVPlayer + MPV), FFmpeg (remux/conversione),
  Google Cast SDK, DLNA, AirPlay, download in background, widget, Siri.

## Dimensioni (file / righe)
| Modulo | File | Righe |
|---|---:|---:|
| Features/Player | 17 | 6 807 |
| Features/Settings | 25 | ~5 200 |
| Features/Details | 13 | 4 656 |
| Services/Remux | 6 | 2 662 |
| Services/Playback | 9 | 2 018 |
| Core/Debrid | 9 | 3 348 |
| Core/Metadata | 16 | 3 044 |
| Core/Playback | 18 | 2 885 |
| Core/Relay | 15 | 2 751 |
| Core/Settings | 6 | 2 107 |
| Test Core | 68 | ~16 700 |
| Test app (unit) | 35 | ~5 500 |
| Test UI | 14 | 3 112 |

## Flussi principali
```
Addon (manifest/catalog/meta/stream/subtitles)
  → AddonService ─ ConcurrencyLimiter ─ withDeadline ─ HTTPClient (NetworkPolicy, redirect validati)
  → ResponseCache (memoria + disco, TTL/stale dell'addon)
  → CatalogAggregator / Search / Metadata enrichment → View model SwiftUI

Riproduzione: StreamPicker → PlaybackRouter → AVPlayer | MPV | LocalRemux (FFmpeg → HLS locale) → PlayerView
Cast: CastCoordinator → GoogleCastBackend | DLNABackend | AirPlay
      → RelayService (server LAN autenticato: file, range HTTP, HLS/DASH riscritti, remux, sidecar sottotitoli)
```

## Dipendenze esterne
Google Cast SDK (GoogleCastDynamic), MPVKit, FFmpeg (via MPVKit/Libavformat), nessun backend proprietario.
Le chiavi (TMDB, TorBox, OpenSubtitles, Trakt…) le inserisce l'utente e restano nel Portachiavi.

Diagramma: [architecture.svg](architecture.svg).
