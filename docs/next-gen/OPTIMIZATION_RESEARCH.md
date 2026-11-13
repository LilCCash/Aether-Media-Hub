# Ricerca sulle ottimizzazioni

Regola: si applica solo ciò che ha un beneficio dimostrabile o un costo nullo; il resto resta proposta con il metodo di
misura. Tabella in [`optimizations.csv`](optimizations.csv).

| ID | Problema | Soluzione | Stato | Rischi | Come misurare |
|---|---|---|---|---|---|
| PERF-01 | Decodifica immagini nell'actor `ImageLoader`: lookup e download in coda dietro ogni decodifica | Decodifica fuori dall'actor, max 3 in parallelo (picco memoria limitato) | **Applicato** | Più memoria transitoria (≤3 bitmap) | Instruments › Allocations e Time Profiler scorrendo una griglia di 200 locandine |
| PERF-02 | I/O sincrono nella `ResponseCache` | Lasciato sincrono: voci piccole, letture solo su mancata memoria; potatura rara (prima scrittura e superamento budget) | Non applicato (nessuna contesa provata) | — | Instruments › File Activity all'avvio |
| PERF-03 | File SwiftUI grandi | Spostamenti senza cambi di codice: Impostazioni per pagina (6 file), `DetailViewModel` ed `EpisodeRow` fuori da `DetailView` (1429 → 1219 righe). `PlayerView` lasciato intero: le sue parti private sono legate allo stato del player | Parziale, applicato | Nessuno (solo spostamenti, build CI verde) | SwiftUI Instruments: conteggio invalidazioni del body |
| PERF-04 | `SWIFT_STRICT_CONCURRENCY: minimal` | Core `complete` 6 → 1. App ora `targeted`: 30 avvisi unici; corretti 7 (4 lock in contesti async, import Spotlight, var→let); restano 23 (MPVEngine 12: `self` catturato nei callback C e conformità attraversa il main actor; Remux/Relay 4: catture non Sendable; 2 codice irraggiungibile innocuo) | Parziale | Correggere MPV richiede ridisegnare i callback del motore | Conteggio avvisi della build CI |
| PERF-05 | Cache memoria sbilanciata | Budget in byte (48 MiB) | **Applicato** | — | Allocations, memoria a riposo dopo 10 min di navigazione |
| PERF-06 | Richieste annullate che occupano permessi | Limiter annullabile | **Applicato** | — | Tempo al primo catalogo dopo cambi rapidi di schermata |

## Già buono, da conservare
Ottimizzazione whole-module in Release; downsampling ImageIO a dimensioni a scaglioni; `NSCache` con limiti;
coalescenza delle richieste uguali (immagini e addon); prefetch limitato a 8; URLSession effimere; download in
background con controllo dello spazio; relay con backpressure; remux in stream copy; `JSONFileStore` con scritture
atomiche e backup.

## Player, HLS e FFmpeg
- Nessun buffer, bitrate, risoluzione o timeout è stato ridotto.
- Rendition HLS: il relay conserva ogni `EXT-X-MEDIA` (verificato da test). Cosa vede il televisore dipende dal
  ricevitore: il Default Media Receiver di Google Cast espone le rendition come tracce; un MP4 progressivo ne espone una.
- FFmpeg: interruzione tramite callback su `isClosed`; ora `start()` chiude anche quando viene annullato.
