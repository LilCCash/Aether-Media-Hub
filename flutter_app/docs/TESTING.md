# Test (2026-10-28)

Eseguiti in questo ambiente con Flutter 3.47.8 (`flutter test`): **70 test, tutti superati**; la CI (`.github/workflows/flutter-ci.yml`) esegue formattazione, analisi statica e gli stessi test su Ubuntu.
Nessun test è stato eseguito su iPhone, iPad, telefono Android o emulatore: **non c'erano** nell'ambiente.

| Area | File | Cosa prova |
|---|---|---|
| Modelli e protocollo | `core_model_test` | manifest (stringhe/oggetti, legacy extra), `provides`, errori leggibili, meta/serie/stagioni, stream (diretto, torrent, header, tracker), politica di rete, `stremio://` e `aether://` |
| Client addon e repository | `addon_client_test` | URL con extra codificati, catalog/meta/stream/subtitles, errori HTTP/JSON/host vietato, cache, annullamento, installazione senza indirizzo in chiaro, riavvio, duplicati, ordine, rinomina, cataloghi nascosti |
| Dominio | `domain_test` | analizzatore e classifica sorgenti, sottotitoli (SRT/VTT/ASS, offset, pulizia, loader), libreria e progresso, impostazioni tolleranti, TorBox (lotti da 100, errori, 409, scelta file, https), TMDB, oscuramento del registro |
| Sessione del player | `player_session_test` | ripresa, salvataggio progresso, tracce preferite e forzati, sottotitoli esterni e offset, errori amichevoli e ripetizione, episodio successivo, cambio sorgente |
| TorBox | `debrid_resolver_test` | solo-in-cache, già nell'account, annullamento, timeout, scelta dell'episodio |
| Download | `download_test` | scarico, persistenza, ripresa con `Range`, errori, indirizzi locali rifiutati |
| Pianificazione | `play_planner_test` | sorgenti dirette, prossimo episodio (cambio stagione, stessa release), sottotitoli unificati, file offline |
| Backup | `backup_test` | niente segreti senza richiesta, ripristino completo, file non valido |
| Interfaccia | `ui_test` | primo avvio → addon → Home, Home vuota, ogni scheda e ogni pagina impostazioni, impostazioni persistenti, scheda titolo e selettore sorgenti, **tasto indietro del player**, controlli del player, errore di riproduzione |
| Colore | `mood_color_test` | colore Cinematic |

**Non eseguiti / non eseguibili qui:** player su dispositivo (MP4, MKV con più tracce, sottotitoli incorporati, ripresa dopo interruzione, formato non supportato), HDR, PiP, rotazione, prestazioni, AirPlay/Cast, TorBox e TMDB reali, addon reali in rete, accessibilità con VoiceOver/TalkBack, avvio con rete assente (il player di prova è offline per costruzione, ma non è stato avviato in modalità aereo).
Il «player di prova offline» è raggiungibile da Altro ▸ Diagnostica; usa `assets/test/aether_test.mp4` e `aether_multitrack.mkv` generati da `tool/make_test_media.sh` (immagine e tono generati da ffmpeg: nessun contenuto di terzi).
