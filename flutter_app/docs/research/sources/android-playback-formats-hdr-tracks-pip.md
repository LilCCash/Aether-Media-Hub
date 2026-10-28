# Android: formati, HDR, tracce, Picture in Picture

**Fonti** (HTTP 200 il 2026-10-28)
- Media3 ExoPlayer, *Supported formats* — https://developer.android.com/media/media3/exoplayer/supported-formats
- Media3 ExoPlayer, *Track selection* — https://developer.android.com/media/media3/exoplayer/track-selection
- *Picture-in-picture (PiP)* — https://developer.android.com/develop/ui/views/picture-in-picture (testo letto)

**PiP (letto).** Da Android 8.0 (API 26) un'attività può passare in PiP; serve `android:supportsPictureInPicture="true"` nel manifest, si chiama
`enterPictureInPictureMode(PictureInPictureParams)` (anche da `onUserLeaveHint`) e `onPictureInPictureModeChanged()` segnala il cambio di modalità.
Aether: manifest con `supportsPictureInPicture` e `resizeableActivity`, `MainActivity.kt` con il canale `app.aether/pip`, interfaccia che nasconde i controlli in PiP.
Il video **continua a decodificare** perché è la stessa attività a restare visibile in finestra ridotta; questo non è stato provato su un telefono.

**Formati e tracce (solo parzialmente letti).** Le pagine di Media3 sono costruite dinamicamente e dal nostro ambiente se ne sono ricavati solo i titoli di navigazione.
Poiché il motore Android di Aether è libmpv e non ExoPlayer, queste pagine non guidano la compatibilità dei file: contano come riferimento per un eventuale adapter Media3 (HDR, DASH, tracce).
**HDR/Dolby Vision:** non applichiamo nessuna conversione cromatica né tone mapping nostri; ciò che avviene è deciso da libmpv e dal display. **Non verificato**.

**Limiti.** Nessun dispositivo/emulatore disponibile: PiP, HDR, decoder hardware e rotazione non provati. Android TV non è un obiettivo di questa versione (vedi LIMITATIONS).
