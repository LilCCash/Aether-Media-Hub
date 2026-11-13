# Aether Next Gen — audit, piano e lavoro svolto

Branch: `aether-next-gen-media-hub`, creato da `aether-swift-features` @ `b9920db` (13/11/2026). Il branch sorgente,
`ci-screenshots` e i branch Android TV non sono stati toccati.

| # | Documento | Contenuto |
|---|---|---|
| 1 | [EXECUTIVE_SUMMARY](EXECUTIVE_SUMMARY.md) | Cosa è stato fatto, cosa resta, cosa non si può verificare qui |
| 2 | [REPOSITORY_ARCHITECTURE](REPOSITORY_ARCHITECTURE.md) | Moduli, dimensioni, dipendenze, flussi principali |
| 3 | [FEATURE_INVENTORY](FEATURE_INVENTORY.md) | Funzionalità e stato reale (+ `feature_inventory.csv`) |
| 4 | [COMPETITOR_ANALYSIS](COMPETITOR_ANALYSIS.md) | Confronto con Stremio, Nuvio, Infuse, Plex, Jellyfin, VLC, Kodi… |
| 5 | [UI_UX_AUDIT](UI_UX_AUDIT.md) | Problemi d'interfaccia, con il loro stato |
| 6 | [REDESIGN_PROPOSAL](REDESIGN_PROPOSAL.md) | «Cinematic clarity»: proposta coerente, cosa è già applicato |
| 7 | [BUG_AUDIT](BUG_AUDIT.md) | Schede dei bug (+ `bugs.csv`) |
| 8 | [SECURITY_AUDIT](SECURITY_AUDIT.md) | Rete, SSRF, DNS, chiavi, log, privacy |
| 9 | [OPTIMIZATION_RESEARCH](OPTIMIZATION_RESEARCH.md) | Ottimizzazioni valutate (+ `optimizations.csv`) |
| 10 | [PERFORMANCE_BASELINE](PERFORMANCE_BASELINE.md) | Cosa è misurato, cosa va misurato sul telefono e come |
| 11 | [TEST_AND_PROFILING_PLAN](TEST_AND_PROFILING_PLAN.md) | Test automatici, sanitizer, Instruments, matrice cast |
| 12 | [IMPLEMENTATION_ROADMAP](IMPLEMENTATION_ROADMAP.md) | Fasi 1-6 con stato |
| 13 | [REGRESSION_MATRIX](REGRESSION_MATRIX.md) | Prima/dopo per ogni modifica |
| 14 | [RESEARCH_SOURCES](RESEARCH_SOURCES.md) | Fonti |
| 15 | [REVIEW_SCOPE_AND_LIMITATIONS](REVIEW_SCOPE_AND_LIMITATIONS.md) | Limiti dichiarati |
| — | [architecture.svg](architecture.svg), [roadmap.svg](roadmap.svg) | Mappa e roadmap visuali |

Regola seguita ovunque: nessuna funzione tolta, nessun limite abbassato senza motivo misurabile, nessun risultato inventato.
