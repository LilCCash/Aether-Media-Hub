# Test (2026-10-29)

Eseguiti in questo ambiente con Flutter 3.47.8 (`flutter test`): **133 test, tutti superati**; la CI (`.github/workflows/flutter-ci.yml`) esegue formattazione, analisi statica e gli stessi test su Ubuntu.
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
| Interfaccia | `ui_test` | primo avvio → addon → Home, Home vuota, ogni scheda e ogni pagina impostazioni, impostazioni persistenti, scheda titolo e selettore sorgenti, Theater Mode (ingresso e uscita, barra scorrevole), link `stremio://` → anteprima addon senza installare, **tasto indietro del player**, controlli del player, errore di riproduzione |
| Colore | `mood_color_test` | colore Cinematic |
| Opzioni e ordine | `prefs_test` | opzioni estese (valori fuori scala, andata e ritorno, `ext` danneggiato), sezioni della Home, ordine delle sorgenti per addon / per qualità, limite di qualità |
| Stagioni | `season_test` | regola di scelta delle sorgenti (lingua, limite rigoroso, più leggere, torrent solo con debrid), riepilogo, opzioni |
| Player che si apre subito | `ui_test` | titolo e stato visibili subito, poi il player; errore spiegato e «Riprova» |
| Servizi opzionali | `services_test` | fanart.tv (scelta del logo, nessuna richiesta senza chiave), MDBList (scale dei voti, duplicati), TheTVDB (login, nuovo login su 401, episodi, chiave non ripetuta), IntroDB (secondi/millisecondi, finestra del pulsante, cache), Real-Debrid (conferma prima di aggiungere, selezione file, link https, token mai negli errori) — tutti con server finti |
| Badge importati | `badge_pack_test` | formato «filters» Nuvio/Fusion e lista semplice, colori con alpha, immagini solo https, espressioni regolari rotte, caricatore (solo https e non locale) |
| Filtri | `filters_test` | tipo/genere/decennio, anno da testo libero |
| Aspetto | `look_test` | palette, caratteri, saluto, impostazioni (andata e ritorno e valori danneggiati) |
| Theater | `theater_test` | preferenze, geometria delle card, validità e ampiezza del WAV generato |
| DLNA | `upnp_test` | descrizione del dispositivo, indirizzi locali, SSDP, SOAP/DIDL, trasmissione e comandi, errori senza il link |

**Non eseguiti / non eseguibili qui:** player su dispositivo (MP4, MKV con più tracce, sottotitoli incorporati, ripresa dopo interruzione, formato non supportato), HDR, PiP, rotazione, prestazioni, AirPlay/Cast, trasmissione DLNA a una TV reale, gesti di luminosità/volume, suono d'ingresso del Theater, TorBox, Real-Debrid, TMDB, TheTVDB, MDBList, fanart.tv e IntroDB reali, addon reali in rete, accessibilità con VoiceOver/TalkBack, avvio con rete assente (il player di prova è offline per costruzione, ma non è stato avviato in modalità aereo).
Il «player di prova offline» è raggiungibile da Altro ▸ Diagnostica; usa `assets/test/aether_test.mp4` e `aether_multitrack.mkv` generati da `tool/make_test_media.sh` (immagine e tono generati da ffmpeg: nessun contenuto di terzi).
