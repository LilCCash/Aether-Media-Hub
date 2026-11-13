# Baseline delle prestazioni

## Misurato in questa sessione (Linux, toolchain Swift 6.0.3)
| Misura | Base `b9920db` | Questo branch |
|---|---|---|
| Test Core | 1056 superati | 1063 superati (+7) |
| Durata suite Core | ~7,7 s | ~8,7 s (test nuovi con attese reali) |
| Thread Sanitizer, suite Core | non eseguito | 0 avvisi |
| Address Sanitizer, suite Core | non eseguito | 0 errori |
| Avvisi Swift 6 (`complete`) nel Core | 6 | 1 |
| Memoria massima della cache risposte | non limitata in byte | 48 MiB |
| Disco massimo della cache risposte | non limitato | 256 MiB |

## Non misurabile qui (serve un iPhone con Xcode)
Avvio a freddo/caldo, apertura Home, tempo al primo frame/audio, rebuffer, RAM/CPU/GPU, batteria, fluidità dello
scorrimento. **Nessun numero è stato inventato.** Procedura:
1. Build Release su dispositivo reale, stesso iPhone per base e branch.
2. Instruments › App Launch (5 avvii a freddo, mediana).
3. Time Profiler + Hitches scorrendo Home e una griglia di Scopri per 30 s.
4. Allocations: memoria dopo 10 minuti di navigazione e dopo «Svuota cache».
5. Player: 5 avvii dello stesso titolo, tempo al primo frame dal log diagnostico.
6. Riportare i valori in questa tabella, colonna per colonna.
