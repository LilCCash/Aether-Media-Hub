# Matrice di capacità dei motori (2026-10-28)

Legenda: **D** = dichiarato dal pacchetto (README/pub.dev) · **P** = capacità della piattaforma · **T** = verificato con test eseguiti · — = non dichiarato / non verificato. **Nessuna riga è «T» per un dispositivo reale: nessun telefono era disponibile.**

| Capacità | media_kit (libmpv) | video_player (AVPlayer/ExoPlayer) | better_player_plus | Verifica in Aether |
|---|---|---|---|---|
| iOS e Android | D iOS 9+/Android 5+ | D iOS 15+/Android SDK 24+ | D | build CI |
| HTTP/HTTPS | D | D | D | — |
| HLS / DASH | D («wide format support»); non testato | P ExoPlayer/AVPlayer: HLS; DASH solo Android | D | — |
| MP4 H.264/AAC | D | D | D | file di prova incluso (non eseguito su telefono) |
| MKV | D | iOS: **no** (AVPlayer); Android: sì | iOS no, Android sì | file di prova MKV incluso |
| Codec video/audio ampi (HEVC, AV1, DTS, TrueHD…) | D libmpv/FFmpeg; dipende dal decoder hardware | dipende dal sistema | dipende dal sistema | — |
| Tracce audio multiple + selezione | D | API limitata | D | T logica con motore finto |
| Sottotitoli incorporati | D | no/limitata | D | T logica con motore finto |
| Sottotitoli esterni | D (mpv) + nostro overlay SRT/VTT/ASS-testo | SRT/VTT (`ClosedCaptionFile`) | SRT/VTT/TTML | T parser + sessione |
| ASS/SSA stilizzato | D mpv per file incorporati/esterni passati al motore; **nostro overlay: solo testo** | no | no | T solo il testo |
| PGS / VobSub | mpv sì in teoria; **non verificato** | no | no | — |
| Sincronia sottotitoli | nostra (overlay esterno); embedded: non regolabile | — | — | T |
| Velocità | D | D | D | T (chiamata al motore) |
| Aspect ratio | D (`fit`) | D | D | T logica |
| HDR10 / Dolby Vision | **non dichiarato**; mpv su Android usa MediaCodec, passthrough non dimostrato | P sistema (AVPlayer HDR su iOS per file compatibili; Android dipende da display/decoder) | non citato | **non verificato** |
| Accelerazione hardware | D | P | P | — |
| PiP | **non dichiarato** | non incluso | D «built-in» | Android: attività PiP (non provata); iOS: assente |
| Background/ciclo di vita | D | D | D | salvataggio progresso su pausa/uscita: T |
| Seek/ripresa | D | D | D | T |
| Errori | D `stream.error` | D | D | T: messaggi comprensibili |
| Memoria/consumo | non misurato | non misurato | non misurato | — |
| Licenza | MIT (+ binari LGPL) | BSD-3 | Apache-2.0 | docs/03 |

Fonti: schede in `../sources/media-player-engines.md` e, per le piattaforme, `ios-…` / `android-…`.
