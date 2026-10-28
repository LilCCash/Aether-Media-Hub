# iOS: riproduzione, tracce, sottotitoli, PiP, AirPlay

**Fonti** (tutte HTTP 200 il 2026-10-28; il testo è renderizzato dinamicamente e dal nostro ambiente è stato estratto solo il titolo)
- *Selecting subtitles and alternative audio tracks* — https://developer.apple.com/documentation/avfoundation/selecting-subtitles-and-alternative-audio-tracks
- *AVPlayerViewController* — https://developer.apple.com/documentation/avkit/avplayerviewcontroller
- *Adopting Picture in Picture in a standard player* — https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-standard-player
- *AVRoutePickerView* — https://developer.apple.com/documentation/avkit/avroutepickerview ; *AVPictureInPictureController* — https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller

**Conoscenza usata (non estratta dalle pagine in questa sessione; da riverificare aprendole):** il PiP di sistema richiede un `AVPlayerLayer` / `AVPictureInPictureController` alimentato da AVPlayer
(o `AVSampleBufferDisplayLayer` con la API di contenuto campione); le opzioni di tracce usano `AVMediaSelectionGroup`; AirPlay si offre con `AVRoutePickerView` e riproduce in modo nativo solo contenuti gestiti da AVPlayer.

**Implicazioni.**
- Con libmpv (media_kit) il video non passa da AVPlayer: **PiP iOS e AirPlay video non sono disponibili** con questo motore. Nell'app il pulsante PiP compare solo su Android; nessun pulsante AirPlay finto.
- Percorso per ottenerli: adapter AVPlayer (video_player o plugin nativo) per i file che AVPlayer sa leggere (MP4/HLS), con ripiego su mpv per MKV: da progettare (ADR-002, «Lavoro residuo»).

**Verificato.** Pagine raggiungibili. **Non verificato** su dispositivo: nulla del comportamento iOS reale.
