# Fonti tecniche di Aether Flutter

Questa cartella conserva **dentro il repository** ciò che è stato letto per prendere le decisioni del progetto, in modo che chi apre il
branch non debba rifare la ricerca né avere accesso alla conversazione in cui è nato. Ogni scheda riporta: URL, ente, data di
consultazione (**2026-10-28**), che cosa è stato **effettivamente letto**, le implicazioni per Aether e le limitazioni.

## Regole
1. Si parte dalla documentazione ufficiale. Le fonti di terze parti si usano solo se aggiungono fatti tecnici concreti.
2. Le schede contengono **sintesi originali** e brevi citazioni: nessuna pagina viene copiata per intero.
3. Un URL «non raggiungibile» dall'ambiente di lavoro è scritto come tale (con l'alternativa usata). Nulla è dichiarato verificato se non è stato letto.
4. Quando una scoperta cambia una decisione, si aggiorna **sia** la scheda **sia** l'ADR collegato.

## Indice
| Argomento | Scheda | ADR collegato |
|---|---|---|
| Interfaccia Flutter, adattività, vetro/blur | [sources/flutter-ui-liquid-glass.md](sources/flutter-ui-liquid-glass.md) | [ADR-004](decisions/ADR-004-glass-ui-performance.md) |
| Canali di piattaforma (iOS/Android) | [sources/flutter-platform-integration.md](sources/flutter-platform-integration.md) | [ADR-003](decisions/ADR-003-platform-native-integration.md) |
| Motori di riproduzione (media_kit, video_player, better_player) | [sources/media-player-engines.md](sources/media-player-engines.md) | [ADR-002](decisions/ADR-002-player-engine.md) |
| iOS: audio, sottotitoli, PiP, AirPlay | [sources/ios-playback-audio-subtitles-pip.md](sources/ios-playback-audio-subtitles-pip.md) | ADR-002/003 |
| Android: formati, HDR, tracce, PiP | [sources/android-playback-formats-hdr-tracks-pip.md](sources/android-playback-formats-hdr-tracks-pip.md) | ADR-002/003 |
| Protocollo addon Stremio | [sources/stremio-addon-protocol.md](sources/stremio-addon-protocol.md) | [ADR-001](decisions/ADR-001-flutter-architecture.md) |
| TMDB e TheTVDB | [sources/tmdb-tvdb-metadata.md](sources/tmdb-tvdb-metadata.md) | ADR-001 |
| TorBox | [sources/torbox-integration.md](sources/torbox-integration.md) | ADR-001 |
| Sottotitoli e accessibilità | [sources/subtitles-and-accessibility.md](sources/subtitles-and-accessibility.md) | ADR-002 |
| Casting e remux | [sources/casting-and-remux.md](sources/casting-and-remux.md) | ADR-003 |
| Sicurezza, privacy, licenze | [sources/security-privacy-licensing.md](sources/security-privacy-licensing.md) | — |

Matrici: [player](compatibility/player-capability-matrix.md) · [piattaforme](compatibility/platform-feature-matrix.md) · [dipendenze](compatibility/dependency-compatibility.md).

## Raggiungibilità degli URL il 2026-10-28 (dall'ambiente di sviluppo)
L'ambiente di lavoro passa da un proxy che blocca alcuni host. Esito del controllo (HTTP 200 = letto, «bloccato» = non raggiungibile, alternativa tra parentesi):

| URL | Esito |
|---|---|
| docs.flutter.dev (adaptive-responsive, platform-channels) | bloccato (si usa il codice sorgente di Flutter su raw.githubusercontent.com e la conoscenza del progetto: vedi le schede) |
| api.flutter.dev BackdropFilter / ImageFiltered | bloccato (letta la documentazione nel sorgente `basic.dart` di Flutter, che è la stessa) |
| pub.dev media_kit, better_player_plus, video_player, flutter_secure_storage | 200 (e API JSON di pub.dev per versioni, date, licenze) |
| developer.apple.com (3 pagine richieste + AVRoutePickerView + AVPictureInPictureController) | 200, solo titolo estratto: contenuto dinamico |
| developer.android.com (formati, tracce, PiP) | 200; PiP letta nel dettaglio, formati/tracce solo parzialmente (pagine con navigazione dinamica) |
| docs.stremio-addons.net, stremio.github.io, github.com/Stremio/… | bloccati o 403 (si usa `raw.githubusercontent.com/Stremio/stremio-addon-sdk` e `/stremio-addons`: 200, letti) |
| developer.themoviedb.org, thetvdb.com | bloccati (TVDB: specifica OpenAPI su raw.githubusercontent.com/thetvdb/v4-api: 200, letta) |
| nuvio.wiki | bloccato (letta la guida su raw.githubusercontent.com/sappy-69/Nuvio-Wiki: 200) |
| api.torbox.app/openapi.json, api.opensubtitles.com | bloccati (si usa `docs/research/torbox-api.md` del repository, ricavato da SDK TorBox e client di terzi) |
| developers.google.com/cast | bloccato |

## Come aggiornare una scheda
1. Apri la fonte, annota data e versione; 2. correggi la sintesi e la sezione «Verificato / non verificato»; 3. se cambia una decisione aggiorna l'ADR;
4. lancia `flutter test` (alcuni test codificano i comportamenti documentati, per esempio i limiti di TorBox).
