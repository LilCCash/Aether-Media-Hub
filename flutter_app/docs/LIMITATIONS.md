# Limitazioni e lavoro residuo (2026-10-28)

**Bloccanti per dire «finito»:** nessuna prova su dispositivo reale, quindi sono *non verificati*: riproduzione con il motore reale, orientamento, PiP Android, prestazioni del vetro, accessibilità.

**Theater Mode:** solo una versione snella (vedi FEATURE_PARITY): nessun suono d'ingresso, nessun effetto proiettore, nessuna impostazione propria.

**Non implementato (e senza pulsanti finti):** AirPlay, Google Cast/DLNA, ponte e remux/transcodifica, PiP su iOS (libmpv), HDR/Dolby Vision garantiti, TheTVDB, MDBList, fanart.tv, Real-Debrid, Salta intro, QR/deep link per aggiungere addon, ricerca nella libreria, personalizzazione completa della Home (palette, cornici, caratteri), modalità chiara, Android TV/telecomando.

**Limitazioni note**
- ASS/SSA dei file *esterni*: solo testo; PGS/VobSub non supportati nell'overlay. Per le tracce incorporate decide libmpv (non verificato).
- La sincronia dei sottotitoli vale solo per quelli da addon.
- Il backup passa dagli appunti (non da file) e include chiavi/indirizzi addon solo su richiesta, **in chiaro**.
- TorBox: `add_only_if_cached` e il contratto completo non sono confermati dall'OpenAPI ufficiale (non raggiungibile); i termini di servizio non sono stati letti.
- Protocollo: l'`id` della risorsa `subtitles` può essere l'hash OpenSubtitles; Aether usa l'ID del video (come molti addon): da verificare con addon reali.
- `usesCleartextTraffic` attivo su Android per gli addon http (segnalati in anteprima).
- Binari libmpv/FFmpeg LGPL: revisione degli obblighi di distribuzione da fare prima di una pubblicazione.
- IPA **non firmato**: richiede firma con il proprio Apple ID/certificato. APK firmato con la chiave di debug: non adatto a uno store.
- Esisteva in precedenza un ramo con lo stesso nome `aether-flutter-comp` con una versione Flutter diversa (ultimo commit `fe43bfc`, 27/10/2026, **non più presente** su GitHub al momento del push); il suo contenuto **non è stato riutilizzato né modificato**.

**Lavoro residuo suggerito, in ordine:** provare su 1 iPhone e 1 Android → adapter AVPlayer (PiP/AirPlay/HDR) → deep link e QR → TheTVDB/MDBList → Theater Mode completo → ponte/remux e Cast.
