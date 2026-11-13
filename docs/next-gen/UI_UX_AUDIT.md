# Audit UI/UX

Riferimenti visivi: il branch `ci-screenshots` è fermo a un commit di 65 commit fa; una nuova galleria del branch è
prodotta dalla CI come artifact `screenshots` (commit con `[shots]`). Nessun difetto «al pixel» è dichiarato senza
aver visto la schermata.

| ID | Problema | Evidenza | Stato |
|---|---|---|---|
| UX-01 | Impostazioni molto ampie, opzioni difficili da trovare | 25 file, ~5 200 righe | **Risolto**: ricerca nelle Impostazioni con risultati diretti alla pagina |
| UX-02 | Hero 430/560 pt su schermi bassi spinge «Continua a guardare» sotto la piega | `HomeComponents.swift` | **Risolto**: invariato da 6,1″ in su, scala sugli schermi più bassi (min 330/420 pt) |
| UX-03 | Carosello che scorre da solo mentre VoiceOver legge | `turnsPages` | **Risolto** |
| UX-04 | Durante il cast, tracce audio del file che spariscono senza spiegazione | `CastTrackControls` | **Risolto**: nota che spiega che il televisore ne riceve una sola |
| UX-05 | Classica e Vetrina hanno destinazioni diverse | `AetherApp.swift` (TabView) | Scelta di design del proprietario: non modificata, vedi REDESIGN_PROPOSAL |
| UX-06 | Scheda titolo con molte pillole/badge | `DetailView` | Proposta (separare badge tecnici/editoriali) |
| UX-07 | Selettore sorgenti denso | `StreamRows` | Proposta (riga primaria + dettagli espandibili) |
| UX-08 | Dynamic Type 200%, Increase Contrast | test UI esistenti parziali | Da verificare su dispositivo |
