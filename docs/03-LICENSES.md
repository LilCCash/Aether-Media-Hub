# Licenze e obblighi — verifica per ogni dipendenza

Questo documento accompagna `NOTICE` e la schermata **Altro ▸ Informazioni e licenze** dell'app.
Le decisioni sono prese sulle licenze pubblicate dai rispettivi repository alla data di sviluppo (ottobre 2026);
**non sono un parere legale**: prima di distribuire su App Store o a terzi, il titolare dovrebbe far verificare le condizioni.

## Dipendenze incluse nell'app

| Componente | Versione | Licenza | Come è usato | Obblighi rispettati |
|---|---|---|---|---|
| Google Cast SDK per iOS (`googlecast/google-cast-ios-sdk`) | 4.8.6 (esatta) | Manifest SPM Apache-2.0; **framework binario proprietario** (Google Cast SDK Additional Developer Distribution Terms) | Scoperta dei dispositivi Cast e invio di un URL al *Default Media Receiver* (`CC1AD845`) | Dichiarato in `NOTICE` e nell'app. Nessun marchio Google usato nell'interfaccia. Il binario non è modificato né ridistribuito separatamente dall'app |
| google/gtm-session-fetcher | transitiva | Apache-2.0 | Dipendenza del Cast SDK | Attribuzione in `NOTICE` |
| Framework Apple | SDK iOS | Apple SDK / Developer Program License Agreement | UI, riproduzione, rete, Portachiavi | Nessun obbligo di attribuzione |

Non ci sono altre librerie di terze parti: AetherCore (modelli, protocollo addon, rete, libreria, sottotitoli, UPnP, backup) è codice originale basato solo su Foundation.

## Riferimenti studiati, non incorporati

| Progetto | Licenza | Uso | Motivazione |
|---|---|---|---|
| stremio-addon-sdk | MIT | Specifica del protocollo | Nessun codice copiato. La licenza MIT consentirebbe di copiare con attribuzione, ma il protocollo si implementa meglio da documentazione |
| stremio-core | MIT | Riferimento di comportamento | Rust: includerlo richiederebbe FFI e cross-compilazione non verificabili qui |
| stremio-web | **GPL-2.0** | Solo lettura funzionale | Copyleft: qualunque derivato dovrebbe essere GPL. Nessun codice, testo, grafica o nome riutilizzato |
| NuvioMobile | **GPL-3.0** | Solo lettura funzionale | Come sopra; inoltre GPL-3.0 è in conflitto con le condizioni dell'App Store e con il SDK Cast proprietario |
| MPVKit / mpv / FFmpeg | LGPL-3.0 (varianti GPL) | **Non incluso** | Obblighi di re-link su iOS, decine di MB, manutenzione dichiaratamente limitata. Resta un'estensione futura dietro il protocollo `PlaybackEngine` |
| VLCKit | LGPL-2.1+ | **Non incluso** | Stesse ragioni (dimensione, re-link) |

## Strumenti di build (non distribuiti)

XcodeGen (MIT) genera il progetto Xcode da `project.yml`. GitHub Actions è usato solo per CI.

## Licenza del progetto

Il codice di Aether è rilasciato con licenza **MIT** (`LICENSE`). È una scelta predefinita del progetto: il titolare può sostituirla, a patto di mantenere le attribuzioni sopra.

## Marchi

«Stremio», «Nuvio», «Google Cast», «AirPlay» e «DLNA» sono marchi dei rispettivi titolari, citati solo per descrivere la compatibilità del protocollo. Nome, icona e interfaccia di Aether sono originali.
