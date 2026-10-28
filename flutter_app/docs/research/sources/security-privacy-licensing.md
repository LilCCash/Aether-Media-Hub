# Sicurezza, privacy, licenze

**Fonti.** pub.dev (licenze dei pacchetti, API JSON), `docs/03-LICENSES.md` del repository, pagina di `flutter_secure_storage` (200).

**Misure implementate**
- Chiavi di servizio (TorBox, TMDB) e indirizzi degli addon (possono contenere la configurazione dell'utente) in archivio sicuro: Keychain (`first_unlock_this_device`) su iOS, archivio cifrato su Android. Mai nel repository, nelle risorse, nei log né nei backup salvo richiesta esplicita.
- `AppLog` oscura `api_key`, `token`, `Bearer …`, `user:password@` e i percorsi dei manifest prima di salvare una riga.
- Gli addon sono terze parti: indirizzi validati (`NetworkPolicy`), nessun URL con credenziali, `localhost`/127.x vietati, rete locale solo con interruttore; risposte limitate in dimensione; nessun codice eseguito.
- Android: `usesCleartextTraffic=true` perché alcuni addon sono http (l'anteprima li segnala). iOS: i socket di libmpv non sono soggetti ad ATS; le chiamate di Dio (dart:io) neppure.

**Licenze principali** (da pub.dev): media_kit / media_kit_video / media_kit_libs_video **MIT** (i binari inclusi libmpv/FFmpeg sono LGPL: vedi `docs/research/compatibility/dependency-compatibility.md`),
Dio, Riverpod, go_router, shared_preferences: BSD/MIT; better_player_plus Apache-2.0 (non usato). Le attribuzioni sono accessibili da Informazioni ▸ Licenze (`showLicensePage`).

**Rischi residui.** Conformità LGPL della distribuzione dei binari mpv/FFmpeg da rivedere prima di una pubblicazione sugli store; termini di TorBox non letti; l'app non fornisce contenuti ed è responsabilità dell'utente ciò che installa.
