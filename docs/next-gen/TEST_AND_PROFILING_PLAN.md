# Piano di test e profiling

## Automatici (eseguiti)
| Livello | Dove | Stato |
|---|---|---|
| Core unit test (1063) | Linux, locale | superati |
| Core con TSan / ASan | Linux, locale | puliti |
| Core su macOS | CI `AetherCore (swift test)` | superati (run 43426226962) |
| App build + unit test (nuovi: relay HLS, impostazioni, immagini) | CI `App (unit tests)` | superati (run 43426226962) |
| UI test Layout, Browse, HomeCustomization, SettingsAndAccessibility, SearchFilter | CI con `ui_tests` | superati (gli unici rossi iniziali erano preesistenti: NEW-03, NEW-04, corretti) |
| UI test TorBox e Metadata | CI con `ui_tests` | 10 fallimenti **identici sul branch di base** `aether-swift-features` (run 43453573172): preesistenti, vedi BUG_AUDIT PRE-01/02 |
| `testChoosingWideCardsInSettingsChangesTheHome` | CI | instabile: passato in run 43426243300 e sulla base, fallito una volta in 43434465261 («install preview did not appear») |
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

## Seconda tornata (commit 5efb6c2 → 29667e0)
| Verifica | Esito |
|---|---|
| Core su Linux (1067 test) e macOS | superati |
| App: build + unit test | superati (run 43486665572) |
| UI test Layout, Browse, HomeCustomization, SettingsAndAccessibility, SearchFilter, **Metadata** | **46/46 superati** (run 43486413144); i 5 Metadata preesistenti ora passano |
| `FFmpegRemuxEngineTests` (riproduzione di un file convertito) | instabile: fallito una volta nella run 43486413144 («No response for media file in 4 s»), superato nelle run 43482118639 e 43486665572 sullo stesso codice |
| UI test TorBox | non rieseguiti: 5 fallimenti preesistenti (PRE-02), identici sul branch di base |
| Build IPA | superata (run 43493439460) |
| Audit accessibilità (informativo) | restano contrasto/Dynamic Type parziale sui testi dell'hero e nomi lunghi degli universi tagliati a schermo grande |
