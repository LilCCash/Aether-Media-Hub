# Limitazioni e lavoro residuo (2026-10-28)

**Bloccanti per dire «finito»:** nessuna prova su dispositivo reale, quindi sono *non verificati*: riproduzione con il motore reale, orientamento, PiP Android, prestazioni del vetro, accessibilità.

**Theater Mode:** versione ridotta (vedi FEATURE_PARITY): niente effetto proiettore né angoli/bordo/alone configurabili; il suono d'ingresso è generato dall'app e non è stato ascoltato su un telefono.

**Ancora da portare (vedi IOS_PARITY_CHECKLIST.md):** tipi di Scopri configurabili, link IMDb dell'episodio, limite in MB della cache immagini, spazio libero, effetto proiettore e foglio a due colonne del Theater, cambio automatico di sorgente per un download già avviato, tema chiaro (solo scuro in Flutter), «densità».

**Non implementato (e senza pulsanti finti):** AirPlay, Google Cast, DLNA su iPhone (la ricerca SSDP richiede un permesso Apple per il multicast), ponte e remux/transcodifica, PiP su iOS (libmpv), HDR/Dolby Vision garantiti, QR per aggiungere addon, cornici/angoli/layout delle card, modalità chiara, Android TV/telecomando.

**Implementato ma mai provato contro il servizio reale o su un telefono:** Real-Debrid, TheTVDB, MDBList, fanart.tv, IntroDB, TorBox, TMDB (solo server finti nei test); gesti di luminosità/volume, trasmissione DLNA, link `stremio://` del sistema, suono d'ingresso del Theater.

**Limitazioni note**
- ASS/SSA dei file *esterni*: solo testo; PGS/VobSub non supportati nell'overlay. Per le tracce incorporate decide libmpv (non verificato).
- La sincronia dei sottotitoli vale solo per quelli da addon.
- Il backup passa dagli appunti (non da file) e include chiavi/indirizzi addon solo su richiesta, **in chiaro**.
- TorBox: `add_only_if_cached` e il contratto completo non sono confermati dall'OpenAPI ufficiale (non raggiungibile); i termini di servizio non sono stati letti.
- Protocollo: l'`id` della risorsa `subtitles` può essere l'hash OpenSubtitles; Aether usa l'ID del video (come molti addon): da verificare con addon reali.
- `usesCleartextTraffic` attivo su Android per gli addon http (segnalati in anteprima).
- Real-Debrid: l'endpoint `instantAvailability` è ritirato (come nell'app iOS), quindi nessuna pillola «in cache»: ogni torrent non ancora nell'account chiede conferma prima di essere aggiunto. I dettagli dell'API sono quelli del client Swift del repository, **non** riletti dalla documentazione ufficiale.
- DLNA: la TV scarica il link da sola; se il formato (per esempio MKV) o le intestazioni richieste dalla sorgente non le vanno bene, la riproduzione fallisce. Solo indirizzi della rete locale; sorgenti con intestazioni segnalate.
- Il volume del gesto verticale è quello del player (0–100 %), non del sistema.
- Binari libmpv/FFmpeg LGPL: revisione degli obblighi di distribuzione da fare prima di una pubblicazione.
- IPA **non firmato**: richiede firma con il proprio Apple ID/certificato. APK firmato con la chiave di debug: non adatto a uno store.
- Esisteva in precedenza un ramo con lo stesso nome `aether-flutter-comp` con una versione Flutter diversa (ultimo commit `fe43bfc`, 27/10/2026, **non più presente** su GitHub al momento del push); il suo contenuto **non è stato riutilizzato né modificato**.

**Lavoro residuo suggerito, in ordine:** provare su 1 iPhone e 1 Android → adapter AVPlayer (PiP/AirPlay/HDR) → QR per gli addon → Google Cast → ponte/remux → rifinitura del Theater Mode.

**Aggiornamento (grafica, download, player):** Liquid Glass reale usa `liquid_glass_renderer` e richiede Impeller + Flutter GPU (abilitati nei manifest); senza, c'è il ripiego con sfocatura. Tema chiaro non implementato (solo scuro). Spazio libero del dispositivo non mostrato. Nulla di questo è stato provato su un dispositivo reale: solo test automatici (126) e analisi statica.

**1.3 beta:** impostazioni riorganizzate per argomento (Aspetto, Home, Scopri, Player, Sorgenti, Cataloghi e metadati, Servizi, Download, Archiviazione, Diagnostica), tutte le tendine chiuse all'apertura. I download di stagione ora vivono nell'app (non nella pagina): uscire dal titolo non li ferma. Lo zoom dalla locandina, la lente della dock con rifrazione e la deformazione «a goccia» non sono provati su un dispositivo; la rifrazione richiede Impeller + Flutter GPU, altrimenti resta la sfocatura. L'errore 503 dei download: aggiunto lo User-Agent `Aether/1.0` come su iOS (la causa più probabile), ma non riprodotto in questo ambiente.
