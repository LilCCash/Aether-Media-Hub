# ADR-004 — Interfaccia «liquid glass» e prestazioni

**Stato:** accettata · **Data:** 2026-10-28

**Decisione.** Linguaggio visivo comune a iOS e Android, costruito con token (`AetherTokens`) e pochi componenti (`GlassSurface`, `GlassButton`, `AetherBackdrop`, `PosterCard`, `Pill`, `SectionHeader`, stati vuoto/errore/caricamento).

**Regole di prestazione.** Blur solo su rettangoli ritagliati e in `RepaintBoundary`; mai a schermo intero; il fondale è un gradiente radiale, non un blur; le immagini usano `memCacheWidth`; liste lazy; il vetro diventa opaco con «Riduci gli effetti», intensità 0 o `disableAnimations` del sistema.

**Cinematic.** Il colore del titolo (media dei pixel di una miniatura 12×12, saturazione/valore limitati per mantenere il contrasto) tinge il fondale; l'artwork nella scheda si dissolve con una maschera, senza stacchi. **AMOLED:** fondo nero assoluto e bagliori ridotti.

**Leggibilità.** Testi chiari su superfici scure; gradienti di protezione sopra le immagini; area minima dei tocchi 44 px; verificati overflow a 360×800.

**Non fatto.** Misure di fluidità su dispositivi; modalità chiara; supporto Dynamic Type oltre quanto Flutter fa da solo.
