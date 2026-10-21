# Licenze e obblighi — verifica per ogni dipendenza

Questo documento accompagna `NOTICE` e la schermata **Altro ▸ Informazioni e licenze** dell'app.
Le decisioni sono prese sulle licenze pubblicate dai rispettivi repository alla data di sviluppo (ottobre 2026);
**non sono un parere legale**: prima di distribuire su App Store o a terzi, il titolare dovrebbe far verificare le condizioni.

## Dipendenze incluse nell'app

| Componente | Versione | Licenza | Come è usato | Obblighi rispettati |
|---|---|---|---|---|
| Google Cast SDK per iOS (`googlecast/google-cast-ios-sdk`) | 4.8.6 (esatta) | Manifest SPM Apache-2.0; **framework binario proprietario** (Google Cast SDK Additional Developer Distribution Terms) | Scoperta dei dispositivi Cast e invio di un URL al *Default Media Receiver* (`CC1AD845`) | Dichiarato in `NOTICE` e nell'app. Nessun marchio Google usato nell'interfaccia. Il binario non è modificato né ridistribuito separatamente dall'app |
| google/gtm-session-fetcher | transitiva | Apache-2.0 | Dipendenza del Cast SDK | Attribuzione in `NOTICE` |
| **MPVKit** (`mpvkit/MPVKit`, prodotto **`MPVKit`** = variante LGPL, **non** `MPVKit-GPL`) | 1.0.0 (esatta; binari con checksum nel manifest di MPVKit) | **LGPL-3.0**. Include mpv 0.41 (LGPL-2.1+ in questa configurazione) e FFmpeg (compilato senza `--enable-gpl`) | Motore di riproduzione alternativo (`MPVEngine`) per MKV, AVI, TS e codec/contenitori che AVPlayer non apre; decodifica hardware con VideoToolbox | Collegamento statico. Il sorgente di Aether è pubblico (MIT) e `project.yml` indica la dipendenza: chiunque può ricompilare l'app con una propria versione di MPVKit, che è ciò che l'LGPL richiede per il re-link. Nome e licenza dichiarati in `NOTICE` e in *Altro ▸ Informazioni e licenze* |
| Librerie impacchettate da MPVKit (FFmpeg, libass, FreeType, FriBidi, HarfBuzz, libplacebo, shaderc, MoltenVK, lcms2, libdovi, libunibreak, dav1d, uavs3d, GnuTLS, Nettle/GMP, OpenSSL, uchardet, libbluray) | come da MPVKit 1.0.0 | LGPL-2.1+/LGPL-3.0, Apache-2.0, MIT, BSD, zlib e simili (nessuna GPL nel prodotto `MPVKit`) | Dipendenze di mpv/FFmpeg | Elencate in `NOTICE`; i testi completi sono nei rispettivi progetti, richiamati da MPVKit |
| Framework Apple | SDK iOS | Apple SDK / Developer Program License Agreement | UI, riproduzione, rete, Portachiavi | Nessun obbligo di attribuzione |

AetherCore (modelli, protocollo addon, rete, libreria, sottotitoli, UPnP, backup, TorBox, TMDB/TheTVDB) è codice originale basato solo su Foundation.

> **Distribuzione.** L'IPA non firmato pubblicato su GitHub è accompagnato dal sorgente completo (licenza MIT per il codice di Aether) e dall'indicazione di MPVKit: questo soddisfa l'obbligo di re-link dell'LGPL per il collegamento statico, a mia lettura. Un'eventuale distribuzione sull'App Store è un caso diverso (le condizioni dello Store aggiungono restrizioni sulla ridistribuzione di software LGPL-3.0 con protezioni DRM) e **va fatta valutare prima**: non è stata valutata qui.

## Riferimenti studiati, non incorporati

| Progetto | Licenza | Uso | Motivazione |
|---|---|---|---|
| stremio-addon-sdk | MIT | Specifica del protocollo | Nessun codice copiato. La licenza MIT consentirebbe di copiare con attribuzione, ma il protocollo si implementa meglio da documentazione |
| stremio-core | MIT | Riferimento di comportamento | Rust: includerlo richiederebbe FFI e cross-compilazione non verificabili qui |
| stremio-web | **GPL-2.0** | Solo lettura funzionale | Copyleft: qualunque derivato dovrebbe essere GPL. Nessun codice, testo, grafica o nome riutilizzato |
| NuvioMobile | **GPL-3.0** | Solo lettura funzionale | Come sopra; inoltre GPL-3.0 è in conflitto con le condizioni dell'App Store e con il SDK Cast proprietario |
| `MPVKit-GPL` (stesso repository) | GPL-3.0 | **Non incluso** | Renderebbe l'intera app GPL; serve solo per il protocollo SMB, che Aether non usa |
| AetherEngine (`superuser404notfound/AetherEngine`) | LGPL-3.0 con eccezione, iOS 18+ | **Valutato, non incluso** | Alternativa citata dal README di MPVKit per l'uso in produzione; richiede iOS 18 (Aether supporta iOS 17) e non c'è modo, dalla sandbox di sviluppo, di provarlo: MPVKit è stato invece compilato ed eseguito in CI. Resta un'opzione futura dietro `PlaybackEngine` |
| KSPlayer | GPL-3.0 (+ licenza commerciale) | **Escluso** | Copyleft incompatibile con la scelta MIT del progetto senza licenza commerciale |
| VLCKit | LGPL-2.1+ | **Non incluso** | Dimensione e stesse implicazioni di re-link; un solo motore alternativo basta |

## Servizi di terzi usati con la chiave dell'utente (nessuna chiave nel codice)

| Servizio | Come è usato | Condizioni |
|---|---|---|
| **TorBox** | API HTTPS con la chiave dell'utente: controllo della cache, avvio di un download, link di riproduzione | Condizioni d'uso **non lette** (pagina renderizzata lato client, non raggiungibile dal probe): vedi `docs/07-SERVIZI.md`. Aether agisce solo su richiesta esplicita dell'utente, con la sua chiave, senza automatismi di massa |
| **TMDB** | Metadati (locandine, trame, cast, episodi) con la chiave dell'utente | Condizioni lette: uso non commerciale (Aether è gratuito e open source), **attribuzione obbligatoria** («This product uses the TMDB API but is not endorsed or certified by TMDB.») mostrata dove compaiono dati TMDB e nelle Impostazioni. Il **logo TMDB non è incluso** (il materiale ufficiale non è stato scaricato né verificato): va aggiunto prima di una distribuzione pubblica più ampia |
| **TheTVDB** | Titoli e trame degli episodi con la chiave dell'utente | Condizioni **non verificate**; credito a TheTVDB mostrato dove usa i suoi dati; l'utente usa una propria chiave e ne risponde |
| **OpenSubtitles** (addon Stremio ufficiale `opensubtitlesv3`) | Sottotitoli tramite il protocollo degli addon, senza chiave né account | L'addon è dell'utente (lo installa lui); Aether non chiama l'API REST di OpenSubtitles |

## Strumenti di build (non distribuiti)

XcodeGen (MIT) genera il progetto Xcode da `project.yml`. GitHub Actions è usato solo per CI.

## Licenza del progetto

Il codice di Aether è rilasciato con licenza **MIT** (`LICENSE`). È una scelta predefinita del progetto: il titolare può sostituirla, a patto di mantenere le attribuzioni sopra.

## Marchi

«Stremio», «Nuvio», «Google Cast», «AirPlay» e «DLNA» sono marchi dei rispettivi titolari, citati solo per descrivere la compatibilità del protocollo. Nome, icona e interfaccia di Aether sono originali.
