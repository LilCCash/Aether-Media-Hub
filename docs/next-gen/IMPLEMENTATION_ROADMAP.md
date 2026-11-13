# Roadmap

| Fase | Contenuto | Stato |
|---|---|---|
| 1 — Correttezza e sicurezza | Limiter, scadenze addon, HTTPClient, LiveRemux, DNS | **Fatta** (test + TSan/ASan) |
| 2 — Memoria e stabilità | Budget cache, file corrotti, immagini | **Fatta**; download e persistenza già solidi (nessun bug trovato) |
| 3 — Prestazioni | Decodifica immagini parallela; profiling Instruments | Parziale: serve un iPhone per misurare |
| 4 — Esperienza | Ricerca impostazioni, hero adattivo, VoiceOver, cast spiegato | **Fatta** la parte non controversa; il resto in REDESIGN_PROPOSAL |
| 5 — Nuove funzioni | Navigazione Vetrina, gerarchia scheda, filtri sorgenti, preset, modalità Essenziale | Da approvare |
| 6 — Validazione | CI completa, UI test, screenshot, IPA | **Fatta**: CI verde (Core, app, unit, UI mirati), IPA run 43432416754; restano i test UI TorBox/Metadata già rotti sulla base |

Prossimi passi consigliati (in ordine): misure Instruments su iPhone → matrice cast con televisori veri →
approvazione delle proposte di redesign → strict concurrency `targeted` nell'app.

Visuale: [roadmap.svg](roadmap.svg).
