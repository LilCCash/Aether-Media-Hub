# Piano di test e profiling

## Automatici (eseguiti)
| Livello | Dove | Stato |
|---|---|---|
| Core unit test (1063) | Linux, locale | superati |
| Core con TSan / ASan | Linux, locale | puliti |
| Core su macOS | CI `AetherCore (swift test)` | vedi esito run CI del branch |
| App build + unit test (nuovi: relay HLS, impostazioni, immagini) | CI `App (unit tests)` | vedi esito run CI del branch |
| UI test mirati (layout, impostazioni, Home) | CI con `ui_tests` | vedi esito run CI del branch |
| Screenshot tour | CI con `[shots]`, artifact `screenshots` | vedi esito run CI del branch |

## Manuali (da fare sul telefono)
- iPhone piccolo (SE/mini) e grande, verticale/orizzontale: Home (hero più basso solo sugli schermi bassi), scheda, player.
- VoiceOver attivo: il carosello non scorre da solo.
- Impostazioni: cercare «torbox», «lingua sottotitoli», «velocità» e aprire i risultati.
- Avvio, Home e scorrimento con Instruments (vedi PERFORMANCE_BASELINE).

## Matrice cast (da fare con televisori veri)
| Sorgente | Google Cast | DLNA (Samsung/LG) | AirPlay |
|---|---|---|---|
| HLS con 2 audio + 2 sottotitoli | tracce dal ricevitore, cambio immediato | una traccia (protocollo) | gestito da iOS |
| MP4 con sottotitoli addon | sidecar VTT, cambio immediato | SRT, cambio con ripartenza | non inviati |
| MKV con più audio (conversione) | cambio audio con ripartenza | cambio audio con ripartenza | conversione locale |
| Seek ripetuti, pausa lunga, cambio sorgente | da provare | da provare | da provare |
