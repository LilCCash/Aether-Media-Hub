# Motori di riproduzione per Flutter

**Fonti** (consultate 2026-10-28)
- media_kit — https://pub.dev/packages/media_kit (200). Dati dall'API di pub.dev: **1.2.6**, pubblicato 13/12/2025, Dart ≥ 3.1; licenza **MIT**; piattaforme Android, iOS, macOS, Windows, Linux, web; 917 like, 364 922 download/30 giorni. README letto da raw.githubusercontent.com/media-kit/media-kit (200).
  Pacchetti collegati: `media_kit_video` 2.0.1, `media_kit_libs_video` 1.0.7 (MIT; includono libmpv/FFmpeg precompilati).
- better_player_plus — https://pub.dev/packages/better_player_plus (200). Versione **2.0.0**, 08/10/2026, Flutter ≥ 3.47.0; licenza **Apache-2.0**; solo Android e iOS; 175 like, ~24 000 download/30 giorni.
  Il README del repository (jhomlala/betterplayer) parla di «Better Player» 1.x con guida «Migrating to 1.x (from 0.0.x / better_player_plus)»: il nome *plus* è la linea precedente.
- video_player — https://pub.dev/packages/video_player (200). Versione **2.14.1**, 02/10/2026, Flutter ≥ 3.44; licenza **BSD-3-Clause**; Flutter Favorite; Android SDK 24+, iOS 15+ (dal README letto in raw.githubusercontent.com/flutter/packages).
  Su iOS usa AVPlayer, su Android ExoPlayer (dal README).

**Cosa dichiara il pacchetto** (non equivale a «funziona su ogni dispositivo»):
| | media_kit | video_player | better_player(_plus) |
|---|---|---|---|
| Motore | libmpv/FFmpeg (stesso su iOS e Android) | AVPlayer (iOS) / ExoPlayer (Android) | AVPlayer / ExoPlayer |
| Codec/contenitori | «Wide format/codec support» (README) | quelli del motore di sistema | quelli del motore di sistema |
| Selezione tracce audio/sottotitoli | sì (README: «Video/Audio/Subtitle track selection»), anche esterne | API limitata (nessuna lista tracce nel README letto) | sì (dichiarato) |
| Sottotitoli | SRT/ASS/… tramite mpv; stile configurabile | solo `ClosedCaptionFile` (SRT/WebVTT) | SRT, WebVTT, TTML, CEA-608/708 (README del repo) |
| PiP | **non dichiarato** nel README | non incluso | dichiarato «built-in» |
| HDR/Dolby Vision | **non dichiarato** | dipende dal motore di sistema | dichiarato solo per DRM/HLS, HDR non citato |
| Dimensione | +30–50 MB (binari mpv; dato del README di better_player) | ~1–2 MB | ~1–2 MB |

**Decisione.** media_kit come motore principale (ADR-002): è l'unico che garantisce lo stesso comportamento su MKV, AVI, HEVC, tracce multiple e sottotitoli ASS su entrambe le piattaforme, che sono ciò che gli addon servono davvero.
Il prezzo è il PiP e l'HDR: vedi limitazioni. L'astrazione `PlaybackEngine` permette di aggiungere un adapter nativo (AVPlayer / Media3) per iOS PiP e HDR senza toccare il resto.

**Verificato.** media_kit compila su Android e iOS in CI; il motore non è stato eseguito su un telefono. **Non verificato:** prestazioni, consumo, HDR, PiP iOS, comportamento con file reali (solo i file di prova inclusi).
