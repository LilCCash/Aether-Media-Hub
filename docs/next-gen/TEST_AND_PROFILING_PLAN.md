# Piano di test e profiling

## Automatici (eseguiti)
| Livello | Dove | Stato |
|---|---|---|
| Core unit test (1063) | Linux, locale | superati |
| Core con TSan / ASan | Linux, locale | puliti |
| Core su macOS | CI `AetherCore (swift test)` | superati (run 43426226962) |
| App build + unit test (nuovi: relay HLS, impostazioni, immagini) | CI `App (unit tests)` | superati (run 43426226962) |
| UI test mirati (Layout, Browse, HomeCustomization, SettingsAndAccessibility) | CI con `ui_tests` | 34/36 al primo giro; i 2 falliti erano preesistenti (NEW-03, NEW-04), corretti e rieseguiti |
| Screenshot tour | CI con `[shots]`, artifact `screenshots` | eseguito (run 43426226962) |

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

## Note dell'audit automatico (informative, non bloccanti)
Contrasto insufficiente su alcune etichette sopra l'artwork («Dettagli», sottotitoli delle righe), testo tagliato e Dynamic Type parziale nei riepiloghi di Universe («17 film · 1 serie»). Da correggere in una fase di redesign con verifica visiva.
