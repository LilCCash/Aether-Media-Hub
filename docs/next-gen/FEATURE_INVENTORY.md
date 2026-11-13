# Inventario delle funzionalità

Stati: **Completa** (codice + test automatici) · **Completa, non provata su dispositivo** · **Parziale** · **Dipende dal ricevitore/servizio**.
Elenco completo in [`feature_inventory.csv`](feature_inventory.csv). In sintesi:

| Area | Stato | Note |
|---|---|---|
| Addon Stremio (installazione, ordine, salute, cache) | Completa | Core + test |
| Home Classica e Vetrina (Liquid Glass), sezioni personalizzabili | Completa | test UI layout/personalizzazione |
| Scopri, categorie, calendario, simili, consigli | Completa | |
| Ricerca e Ricerca avanzata (filtri, indice locale) | Completa | |
| Scheda titolo ricca (cast, trailer, premi, moduli) | Completa | |
| Universe (mappa, ordini, avanzamento) | Completa | |
| Libreria, watchlist, cronologia, diario, statistiche | Completa | |
| Trakt (accesso, scrobbling, sync) | Completa, non provata su dispositivo | dipende dal servizio |
| Sincronizzazione iCloud | Parziale | modulo Core `Sync` piccolo (45 righe): da verificare con due dispositivi |
| Player AVPlayer + MPV, HDR/DV, PiP, velocità, gesti, intro skip | Completa, non provata qui | PiP solo AVPlayer |
| Sottotitoli addon/OpenSubtitles/file, doppi sottotitoli, stile | Completa | |
| Download, stagioni, sottotitoli nei download | Completa | |
| Remux MKV → HLS locale, conversione | Completa, non provata su dispositivo | |
| Google Cast: sottotitoli dal telefono, cambio tracce immediato | Dipende dal ricevitore | audio multiplo solo se il ricevitore lo espone |
| DLNA: sottotitolo SRT (CaptionInfo/DIDL) | Dipende dal ricevitore | Samsung/LG di solito sì |
| AirPlay | Completa | tracce gestite da iOS |
| Live TV, playlist, guida XMLTV | Completa | |
| Widget, Siri, SharePlay | Completa, non provata qui | |
| Ricerca nelle Impostazioni | **Nuova** in questo branch | |
