# Dipendenze (2026-10-28) — versioni risolte, licenza, compatibilità, rischi

Fonte versioni/date/licenze: API JSON di pub.dev; vincoli SDK: `pubspec.yaml`. Toolchain: Flutter 3.47.8, Dart 3.13.7.

| Pacchetto | Versione | Licenza | Perché | Alternative | Rischi noti |
|---|---|---|---|---|---|
| flutter_riverpod | ^3.4.3 | MIT | stato/DI | bloc, provider | API in evoluzione (3.x) |
| go_router | ^18.1.1 | BSD-3 | routing dichiarativo | auto_route | cambi di API tra major |
| dio | ^5.11.1 | MIT | HTTP con cancellazione e adapter | http | — |
| shared_preferences | ^2.5.6 | BSD-3 | impostazioni/libreria JSON | drift, hive | non adatto a grandi volumi |
| flutter_secure_storage | ^11.2.0 | BSD-3 | chiavi e indirizzi addon | keychain nativo | comportamento Android su restore backup di sistema |
| path_provider | ^2.1.6 | BSD-3 | cartelle download/temp | — | — |
| media_kit / media_kit_video / media_kit_libs_video | 1.2.6 / 2.0.1 / 1.0.7 | MIT (+ binari LGPL) | motore (ADR-002) | video_player, better_player | +30–50 MB; PiP/HDR non dichiarati; obblighi LGPL sulla distribuzione |
| wakelock_plus | latest risolto | BSD-3 | schermo acceso | — | canale nativo (fallisce in test: gestito) |
| cached_network_image | ^4.0.5 | MIT | cache immagini | — | richiede plugin di piattaforma (disattivato nei test) |
| url_launcher | ^6.3.3 | BSD-3 | trailer, configurazione addon | — | — |
| crypto, path, intl | — | BSD-3 | utilità | — | — |
| mocktail (dev) | — | MIT | test | — | — |

Controllo licenze: elenco delle dipendenze transitive nella CI («Dependency licences») e `showLicensePage` nell'app. Revisione legale LGPL: **da fare** prima di una pubblicazione.
