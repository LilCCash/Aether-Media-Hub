# Aether Alpha 2 (v1.0.0-alpha.2): note di rilascio e problemi noti

Pre-release **non firmata** (`Aether-unsigned.ipa`, ~20 MB): iOS non la installa così com'è, va firmata di nuovo con il tuo Apple ID (AltStore, Sideloadly) o con un certificato tuo.
Nel repository non sono configurate credenziali di firma e l'IPA **non è stato provato su un iPhone**. Questa pagina elenca solo cose realmente presenti nel codice; per ciascuna dice se è
stata provata e come. Il dettaglio dei test è in [`04-TESTING.md`](04-TESTING.md).

## Cosa cambia rispetto ad Alpha 1

**Correzione grafica (scheda dettaglio e carosello Home tagliati ai lati).** Causa trovata con test di geometria che riproducevano il difetto prima della correzione: un'immagine disegnata con
«riempi» riportava al layout una larghezza maggiore dello spazio disponibile (un fondale 16:9 in uno spazio stretto) e l'eccesso allargava l'intera schermata. `RemoteImage` ora disegna dentro una base
che prende esattamente lo spazio proposto e ritaglia; il carosello è una vista a pagine (`ScrollView` + `scrollTargetBehavior(.paging)`). Verificato in CI con test che misurano larghezza del contenitore, centro della
pagina e distanza tra le pagine su più schermate (dettaglio film, dettaglio serie, scelta della sorgente, Home).

**Riproduzione (HDR / Dolby Vision / formati).** Secondo motore **MPV (MPVKit, LGPL)** accanto ad AVPlayer, scelto da `PlaybackPlanner` in base a ciò che il file dichiara (contenitore, codec, tag `hvc1`/`hev1`, profilo Dolby Vision, `isDecodable`),
con passaggio automatico all'altro motore, una volta, se il primo non apre il file. MKV e gli altri contenitori non nativi vengono affidati a MPV. Provato nel simulatore in CI con file generati da ffmpeg: H.264 in Matroska, HEVC Main10 HDR10 in MP4 (AVPlayer) e in MKV (MPV), HEVC `hev1` (scelto MPV), HEVC 8 bit raggiungono la riproduzione. **AVI e HLG in MP4 non si sono aperti nell'ultima esecuzione** (causa non chiarita), e **non è confermato che il foglio informazioni mostri codec e gamma dinamica letti dal decoder** (mostra contenitore e motore). Il badge HDR/Dolby Vision viene dal file, non dal nome (i badge dal nome sono etichettati «nel nome»); il foglio «Informazioni sulla sorgente» separa dichiarato, rilevato e atteso.
**Vero Dolby Vision solo con AVPlayer** (MP4/MOV/HLS, profili 5/8.x); con MPV un file Dolby Vision è mappato su HDR10 o SDR e descritto così. Nessun file Dolby Vision reale è stato provato (nessun encoder in CI) e l'aspetto
reale su uno schermo HDR non è verificato. Matrice completa e limiti: [`06-PLAYBACK.md`](06-PLAYBACK.md).

**Impostazioni del player (ispirate a Nuvio, solo quelle che fanno qualcosa):** motore, uscita HDR, tone mapping, decodifica hardware, deband, luminosità/contrasto/saturazione/gamma, buffer, lingue audio e sottotitoli primarie e secondarie,
tenere premuto per accelerare, pulizia dei tag per non udenti nei sottotitoli.

**Sottotitoli da addon.** In *Addon ▸ Consigliato* compare OpenSubtitles v3 (non viene mai installato da solo). Gli addon di sottotitoli ricevono nome del file e, quando calcolabile sul dispositivo, l'hash OpenSubtitles del video;
i risultati sono classificati per lingua, raggruppati, filtrabili, con scelta automatica (primaria, secondaria), lingua ricordata per la serie e stati vuoti ed errori onesti.

**TorBox (con la tua chiave).** *Impostazioni ▸ Servizi*: chiave nel Portachiavi, verifica della connessione, «In cache» / «Non in cache» nella lista delle sorgenti, riproduzione dei torrent già in cache, download su conferma con avanzamento. «TorBox Instant» non
esiste come funzione separata: «istantaneo» vuol dire *in cache*. Aether non cancella né ripara mai nulla nel tuo account. **TorBox reale non è stato mai contattato**: tutto è provato contro stub e un server di prova costruito dalla documentazione ([`07-SERVIZI.md`](07-SERVIZI.md)).

**TMDB e TheTVDB (con la tua chiave).** Completano solo i dati che l'addon non ha (locandina, sfondo, logo, trama, cast, durata, titoli ed episodi); mai sovrascritti i dati dell'addon; id incrociati IMDb/TMDB/TVDB; attribuzione mostrata.
Con chiave reale non provato; il logo TMDB non è incluso.

**Cerca e Scopri.** Cerca ha i menu Tipo / Genere / Anno / ordinamento, con tipi dinamici (Film, Serie TV, TV, sport…) dagli addon installati; i filtri sono inviati all'addon solo se il suo manifest li dichiara, il resto è locale con il numero di risultati nascosti.
Scopri ha tipi dinamici e, in *Impostazioni ▸ Aspetto ▸ Categorie di Scopri*, mostra/nascondi e ordine.

**Altro.** La ricerca recente rispetta ora l'interruttore «Salva le ricerche recenti»; «Elimina tutti i dati locali» aggiorna anche lo stato delle chiavi dei servizi; testi di privacy e istruzioni TorBox resi accurati; correzioni dall'audit (sotto).

## Problemi noti (non corretti in Alpha 2)

Elenco dall'audit indipendente del codice (sette aree di revisione; **le verifiche incrociate dei risultati e tre aree — prestazioni, correttezza logica, affermazioni nei documenti — non sono state completate** per un limite di utilizzo del servizio di revisione). Sono segnalazioni di un
revisore automatico, lette dal codice e **non riprodotte su dispositivo**.

*Sicurezza*
* **libmpv non verifica i certificati TLS** (opzione `tls-verify` di mpv spenta di default): le sorgenti riprodotte da MPV (MKV/AVI/TS e MKV serviti da TorBox) non sono protette dall'attacco «man in the middle». AVPlayer verifica. Correzione prevista: includere un file di CA e attivare `tls-verify` (non fatto: senza un file di CA tutti i flussi https di MPV fallirebbero e non c'è modo di provarlo qui). Si basa sul codice (`MPVOptions` non imposta `tls-verify`) e sui valori predefiniti di mpv; non provato con un certificato non valido.
* Il motore MPV segue i reindirizzamenti con la propria rete: `NetworkPolicy` convalida solo il primo indirizzo (dichiarato in `06-PLAYBACK.md`).
* Il collegamento di download restituito da TorBox potrebbe essere `http`; l'host dei client TorBox/TMDB/TVDB è controllato dopo un reindirizzamento e non prima dell'invio (l'intestazione `Authorization` non viene tolta).
* MPVKit e Google Cast sono fissati per tag, non per revisione (`Package.resolved` non è nel repository).
* I parametri `-AETHER_UITEST_*` sono compilati anche nella build Release (agiscono solo con `-AETHER_UITEST`).
* Le chiavi dei servizi restano nel Portachiavi se si elimina l'app (comportamento di iOS) e non c'è un'eliminazione al primo avvio.
* Workflow: `ci.yml` senza blocco `permissions`; segreti di firma visibili a tutti i passi del job firmato (mai eseguito).

*Riproduzione e ciclo di vita*
* Per i torrent TorBox il cambio automatico di motore (ripiego su MPV/AVPlayer) viene annullato da `adoptEngine`: il ripiego non scatta.
* Possibile blocco del thread principale nel layer Metal di MPV (segnalato, non verificato su dispositivo); l'audio di sistema è disattivato mentre MPV si sta ancora chiudendo.
* «Tieni premuto per accelerare»: il gesto potrebbe scattare a ogni tocco e finire prima del rilascio (segnalato dall'audit, non provato su dispositivo).
* Il foglio «Cambia sorgente» del player elenca i torrent senza badge di cache.
* Un errore di un addon di sottotitoli appare come «nessun sottotitolo trovato» (nessun tentativo di nuovo); l'importazione di un sottotitolo locale legge tutto il file senza limite.

*Interfaccia e accessibilità*
* Chip dei filtri alti ~36 pt (meno di 44), pulsanti −0,5/+0,5 del ritardo sottotitoli piccoli, cursori delle regolazioni immagine senza etichetta per VoiceOver, segnaposto lunghi troncati su iPhone piccoli con testo grande, contrasto dei testi verde/arancione dello stato dei servizi, nessuno stato di caricamento nelle informazioni del decoder, tracce audio dopo la prima senza titolo.
* Il carosello a pagine ha perso la navigazione a pagine di VoiceOver e l'avanzamento automatico ignora l'interazione.

*Dati*
* `downloads.json.bak` e `addons.json.bak` restano dopo «Elimina tutti i dati locali»; nessun test verifica che le chiavi dei servizi non finiscano nei backup (il codice non le include).

## Corretti dopo l'audit (in questa versione)

* L'avvio della riproduzione non può più caricare una sorgente in un motore già chiuso né farsi superare da un avvio più recente (rischio di uso dopo la liberazione in libmpv).
* Cambiando episodio la posizione dell'episodio precedente non viene più salvata come quella del successivo.
* «Elimina tutti i dati locali» aggiorna lo stato delle chiavi (TorBox, TMDB, TheTVDB).
* Testo di privacy aggiornato (le richieste ora possono andare anche a TorBox, TMDB e TheTVDB se inserisci una chiave); istruzioni TorBox senza percorsi di menu non verificati; spiegazione del casting per i torrent TorBox; singolari nei messaggi; interruttore «Salva le ricerche recenti» collegato.
