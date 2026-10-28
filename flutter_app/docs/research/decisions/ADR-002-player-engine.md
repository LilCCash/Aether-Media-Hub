# ADR-002 — Motore di riproduzione

**Stato:** accettata con riserve · **Data:** 2026-10-28

**Decisione.** Motore principale **media_kit (libmpv/FFmpeg)** su iOS e Android, dietro l'interfaccia `PlaybackEngine`.

**Perché.** Gli addon servono MKV/AVI/HEVC con più tracce e sottotitoli: libmpv li legge in modo uniforme su entrambe le piattaforme; `video_player` e `better_player_plus` usano i motori di sistema (AVPlayer/ExoPlayer), che su iOS non aprono MKV né molti codec e hanno API limitate per le tracce. Confronto in `compatibility/player-capability-matrix.md`.

**Costi accettati.** (1) **PiP iOS e AirPlay video non disponibili** con libmpv; (2) **HDR/Dolby Vision non garantiti** (nessun passthrough dimostrato, nessuna conversione nostra); (3) app più pesante (+30–50 MB); (4) PiP Android implementato a livello di attività, non provato su dispositivo.

**Lavoro residuo.** Adapter nativi per piattaforma dietro la stessa interfaccia: AVPlayer (PiP, AirPlay, HDR dei file compatibili) per iOS e Media3 per Android, scelti per formato. Richiede dispositivi per validare. Finché non c'è, l'interfaccia non mostra comandi che non funzionano.

**Verifica.** Logica di sessione provata con motore finto (`test/player_session_test.dart`) e con la schermata (`test/ui_test.dart`); il motore reale è compilato in CI ma **non eseguito** su un telefono.
