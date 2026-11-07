# Aether rifatta — stato

L'interfaccia Pro è ora **l'unica** di Aether: non esiste più l'interruttore Classica/Pro né Theater Mode.
**Nulla è provato su un iPhone.** ✅ nel codice (con test dove possibile, in CI) · 🟡 sperimentale o parziale.

| Area | Stato | Note |
|---|---|---|
| Barra di sistema: Home, Scopri, Libreria, Profilo + Ricerca separata | 🟡 | Ruolo «search» di `Tab` (iOS 18; Liquid Glass da iOS 26). Prima di iOS 18 resta la barra a 5 voci. |
| Aspetto rifatto: stili pronti, colori, sfondo, schede, movimento | ✅ | `AppearanceSettings` (schema 2) e `LookPreset`; chi aggiorna riparte dallo standard (nome, ordine Home, libreria restano). Test in Core. |
| Profilo: matita (modifica), ingranaggio (Impostazioni), Il mio universo, diario, statistiche, confronto voti, gusti | ✅ | Diario/timeline/statistiche solo qui. |
| Storage con barra Film/Serie/Cache/Altro e spazio recuperabile | ✅ | Film/Serie dai download; «recuperabile» = cache + file inutilizzati + download già visti. |
| Artwork Explorer, sfondi iPhone, modalità ambiente | 🟡 | Immagini TMDB (chiave tua). Gli sfondi si salvano nelle Foto (permesso «solo aggiungere»). Niente trailer/colonna sonora nell'ambiente. |
| Scoperta cinematografica, Calendario uscite (promemoria), consigli AI | 🟡 | TMDB; promemoria = notifica locale alle 10 del giorno di uscita; l'AI usa il modello scelto in Ricerca avanzata. |
| Mappa della timeline degli universi | ✅ | Ordine di uscita e, dove c'è, ordine della storia (editoriale). |
| Apertura cinematografica (suono originale) e titoli di coda in scena | 🟡 | Il suono è sintetizzato nel codice. L'apertura mette in pausa il film finché non finisce. |
| Chat del cinema insieme | 🟡 | Sopra SharePlay (serve l'entitlement; con SideStore può non esserci). |
| Intelligenza delle fonti che impara | ✅ | `SourceReliability`: bonus da -60 a +30 per addon dopo 3 riproduzioni, spegnibile. |
| Live TV: cataloghi che rispondono con una pagina | 🟡 | Secondo tentativo con User-Agent da browser e messaggio chiaro; non verificato con i servizi reali. |
| Universe, Persone, Companion, PiP con MPV, anteprime FFmpeg, sincronizzazione cartella, handoff | come prima | Vedi le note delle build precedenti. |
