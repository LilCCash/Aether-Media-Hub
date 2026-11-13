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
| UX-05 | Classica e Vetrina hanno destinazioni diverse | `AetherApp.swift` (TabView) | **Opzione**: «Scopri nella barra in basso» (spenta di default, la Vetrina resta com'era) |
| UX-06 | Scheda titolo con molte pillole/badge | `DetailView` | Proposta (separare badge tecnici/editoriali) |
| UX-07 | Selettore sorgenti denso | `StreamRows` | **Filtri rapidi** qualità/HDR/lingua (disattivabili); riga espandibile resta proposta |
| UX-08 | Dynamic Type, contrasto su immagini | audit automatico CI | **Corretto** sulle schede Universe e sull'hero (ombra disattivabile); resto da verificare su dispositivo |
| UX-09 | Impostazioni intimidatorie al primo avvio | 17 pagine | **Opzione** «Impostazioni essenziali» (spenta di default) |
