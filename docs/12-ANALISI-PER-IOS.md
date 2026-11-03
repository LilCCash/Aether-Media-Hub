# Analisi per iOS — stato, lacune, cosa provare, idee

*Documento di lavoro, 3 novembre 2026 (build di sviluppo 135, ramo `aether-swift-features`). Compagno di [13-BUGFIXING-PER-IOS.md](13-BUGFIXING-PER-IOS.md).*

**Come leggerlo.** Ogni affermazione ha un'etichetta di affidabilità:
**[C]** letto nel nostro codice o nei nostri log · **[W]** trovato online (fonte nel §9) · **[S]** conoscenza mia, *da verificare* · **[?]** non so, va provato.
Nessuna funzione qui descritta come "da provare" è stata provata su un iPhone: lo dico una volta per tutte.

---

## 1. Fotografia di oggi

| Dato | Valore |
|---|---|
| Righe di Swift (app + Core) | circa 72.000 **[C]** |
| File di test | 87 (Core, app, UI) **[C]** |
| Flussi CI | `ci.yml` (test Core + app + UI), `build-ipa.yml` (IPA non firmato + source SideStore) **[C]** |
| Cartelle funzione | Addons, Casting, Details, Discover, Downloads, Home, Library, Player, Search, Settings, Theater, Trakt **[C]** |
| Distribuzione | IPA non firmato, installato con SideStore dalla source `devbuilds` **[C]** |
| Mai provato su hardware (dal nostro README) | AirPlay con Apple TV, Google Cast, DLNA, Picture in Picture, HDR/Dolby Vision, VoiceOver, Theater Mode **[C]** |

Funzioni consegnate da giugno in poi, tutte **non provate su dispositivo** finché non lo dici tu: ricerca avanzata con AI (7 fornitori + Apple Intelligence), indicizzazione Spotlight, Trakt (accesso, cataloghi, sincronizzazione, scrobble), TV in diretta (cataloghi con genere obbligatorio, lettore a parte), copia link e lettori esterni (anche torrent via debrid), scheda Cloud (TorBox + Real-Debrid), pack di stagioni (apertura, scelta, download), episodi scaricati per primi, salta intro offline, download letti dal contenuto, LiveContainer, link di riproduzione via debrid.

## 2. Cosa manca davvero (lacune verificate nel codice)

Ricerca nel codice del 3/11: **0 occorrenze** di MetricKit, `Logger`/`OSSignposter`, ActivityKit, WidgetKit, GroupActivities (SharePlay), CarPlay, BGTaskScheduler, `NSUserActivity` (Handoff), notifiche locali, CloudKit, SwiftData, TipKit, file `Localizable` **[C]**.

| # | Lacuna | Perché conta | Note |
|---|---|---|---|
| L1 | **Nessuna diagnostica di crash/hang** (niente MetricKit) | I crash del telefono arrivano solo se li racconti tu | MetricKit funziona uguale per app sideloaded? **[?]** (nessuna fonte lo conferma; l'API è la stessa **[W]**, ma va provato) |
| L2 | **Log non strutturato** (solo il nostro `DiagnosticLog`, niente `os.Logger` né signpost) | Instruments, `Console.app` e `sysdiagnose` non vedono i nostri log | vedi §3.2 del documento bugfixing |
| L3 | **Nessun pulsante "Segnala un problema"** che impacchetti log + build + impostazioni | Ogni bug costa 3-4 scambi per capire il contesto | idea P1 |
| L4 | **UI test che si bloccano in CI** (un run è rimasto in "UI tests" oltre un'ora; due CI annullate) | Senza CI affidabile ogni modifica è alla cieca | indagare: timeout per test, simulatore, server fixture **[C]** |
| L5 | **CI di `920c403` (ultime funzioni) mai conclusa verde** | I test dell'app su quel codice non sono verificati | rilanciare quando decidi |
| L6 | **Interfaccia solo in italiano** (stringhe nel codice, nessun catalogo) | Se l'app diventa pubblica serve l'inglese | basso costo con String Catalog, alto con 72k righe già scritte |
| L7 | **Nessuna notifica "nuovo episodio"** | È la funzione che fa tornare nell'app | notifiche locali + calendario Trakt, senza server (§5) |
| L8 | **Nessun widget / Live Activity / Handoff** | "Continua a guardare" sulla Home di iOS è molto atteso | vincoli dei sideload, §6 |
| L9 | **Nessun controllo di salute delle fonti** (le fonti che non partono si scoprono toccandole) | Tempo perso a ogni visione | idea P1 |
| L10 | **Backup incompatibile tra Swift e Flutter** (risposta data) | Chi cambia versione perde dati | decidere se unificare il formato |
| L11 | **PiP solo con AVPlayer** (MPV no) **[C]** | La maggior parte dei file è MKV | ricerca lunga, §5 W3 |
| L12 | **403 geolock sui canali** non diagnosticati | Servono nome canale + messaggio + log | in attesa dei tuoi dati |
| L13 | Impostazioni minori note: righe del log tempi con servizi non usati; modello Google di default `gemini-2.5-flash` non più disponibile ai nuovi utenti **[C]** | Piccoli difetti visibili | fix da 15 minuti ciascuno |
| L14 | **Fiducia nell'aggiornamento di SideStore sopra l'app esistente** | Se tratta la build come nuova, si perdono i dati | provare con backup |

## 3. Cosa provare, in ordine di rischio

Criterio: prima ciò che può **far perdere dati o impedire di aprire l'app**, poi ciò che rende inutilizzabile la funzione principale (guardare), poi il resto. Ogni riga ha l'esito atteso; segna sotto "ok / no / note".

### Blocco A — Può far male (fai un backup prima: Impostazioni ▸ Backup)
1. **Aggiornamento sopra l'installata** con SideStore: l'app resta, libreria e chiavi ci sono. *Se tratta come nuova → fermati.*
2. **Ripristino da file** di un backup recente (il difetto trovato in 1.2): libreria, cronologia, addon tornano.
3. **Download già esistenti** dopo l'aggiornamento: si aprono; i vecchi episodi recuperano da soli intro/riassunto al primo avvio con rete.
4. **Backup che passa tra build**: esporta dalla 135, importa in una successiva.

### Blocco B — Guardare (il motivo per cui l'app esiste)
5. Un MP4 diretto, un MKV diretto, un torrent in cache: avvio, pausa, riprendi, seek, cambio audio, sottotitoli.
6. MKV con motore Automatico, poi AVPlayer fisso, poi MPV fisso: ogni scelta apre o spiega perché no.
7. Errore del player (sorgente rotta): **"Chiudi" funziona al primo tocco**, anche se l'errore compare subito.
8. Episodio dopo episodio: tasto "Successivo", fine puntata, countdown; con **download presente** apre il file senza rete.
9. Pack di stagione (torrent con tutti gli episodi): apri un episodio dal pack, scegli "pack / cerca / elenco" dalla lista episodi, scarica più episodi.
10. **Download** con link senza estensione, poi AVPlayer: nessun errore (file riconosciuto dal contenuto).
11. **Salta intro/riassunto**: online e offline su un episodio scaricato.
12. Live TV: Discover con catalogo "genere obbligatorio", lettore dirette a parte; i canali 403 → manda nome canale, messaggio e log.

### Blocco C — Collegamenti
13. **Trakt**: collega, cataloghi (trending, watchlist, calendario), aggiungi alla watchlist, scrobble di un episodio guardato. Se esce ancora -1005, dimmelo con l'ora.
14. **Ricerca avanzata**: una frase ("film simili a Toy Story") per ogni fornitore che usi, tasto "Verifica chiave", log dei tempi.
15. **Indicizzazione**: "Indicizza ora" e poi cerca un titolo dalla ricerca di iOS; chiudi l'app e ricontrolla.
16. **Cloud**: scheda Libreria ▸ Cloud con TorBox e Real-Debrid, menu di scelta, apertura di un file.
17. **Copia il link**, **link di riproduzione via debrid** (si incolla in un browser e parte), avviso di sicurezza visibile.
18. **Lettori esterni** (VLC, Infuse…), poi **LiveContainer** con l'id giusto; poi con id sbagliato (deve fallire senza danni).

### Blocco D — Mai provati dal vivo (dal README)
19. AirPlay verso Apple TV, anche con MKV convertito; Google Cast e DLNA verso un televisore vero.
20. Picture in Picture con un MP4 (con MKV deve spiegare perché no).
21. HDR e Dolby Vision su un file vero (iPhone 18 Pro Max): colori corretti, niente "lavati".
22. VoiceOver sul percorso principale: Home → dettaglio → riproduci.
23. Theater Mode: aspetto e animazioni.

**Per ogni problema mi servono:** numero build, cosa stavi facendo, cosa ti aspettavi, cosa è successo, il log (Impostazioni ▸ Diagnostica) e, se possibile, una schermata.

## 4. Cose importanti da aggiungere (P1)

Ordine suggerito = valore ÷ costo.

| # | Funzione | Valore | Costo | Rischio |
|---|---|---|---|---|
| P1.1 | **"Segnala un problema"**: un tasto che crea un file con build, modello iPhone, iOS, impostazioni (senza chiavi), ultime 300 righe di log e ultima schermata d'errore, da condividere con il foglio di iOS | Dimezza il giro per capire un bug | basso (1 giorno) | nessuno; il file non contiene segreti (passa dal `Redactor`) |
| P1.2 | **MetricKit** (`MXMetricManager`) + lettura crash/hang al prossimo avvio, mostrati e allegabili al rapporto | Vedi i crash che altrimenti non vedo | basso | funzionamento su sideload **[?]**; note su iOS 17.2–17.5 dove non arrivavano **[W]** |
| P1.3 | **`os.Logger` + signpost** su apertura sorgente, risoluzione debrid, avvio motore, ricerca, download | Strumenti di iOS (Instruments, Console) leggono finalmente l'app | basso | nessuno |
| P1.4 | **Salute delle fonti**: dopo un esito (parte / non parte / lento) memorizzo per addon e dominio; ordino e mostro un puntino | Meno tocchi a vuoto | medio | falsi negativi: soglie prudenti |
| P1.5 | **CI affidabile**: timeout per test UI, `-retry-tests-on-failure`, artefatto con screenshot e `.xcresult` | Fiducia nelle verifiche | medio | richiede ore di prove su macOS runner |
| P1.6 | **Novità in app**: foglio "Cosa c'è di nuovo" che legge lo stesso `docs/devbuild-notes.md` della source | Capisci cosa provare senza me | basso | nessuno |
| P1.7 | **Controllo aggiornamenti** (legge `source.json`) con tasto "Apri in SideStore" | Nessuna ricerca manuale delle build | basso | schema di SideStore per aprire l'IPA **[?]** da verificare |
| P1.8 | **Notifiche "nuovo episodio"** con calendario Trakt e notifiche locali | Motivo per tornare nell'app | medio | affidabilità del refresh in background su sideload **[?]** |
| P1.9 | **Scarico automatico del prossimo episodio** quando sei in Wi-Fi e hai finito quello corrente | Wow pratico: episodio sempre pronto | medio | spazio e rete: limiti chiari |
| P1.10 | Correzioni minori L13 (log dei tempi, default Gemini) | Pulizia | 15 min | nessuno |

## 5. Idee funzionali e "da restare a bocca aperta"

Etichette: **Effetto** (stupore), **Fattibilità**, **Vincolo**. Dove non so, lo scrivo.

### W1 — "Cosa mi sono perso?" (riassunto senza spoiler con AI locale)
Riprendendo una serie dopo giorni, un foglio sintetizza *fino all'ultimo episodio visto* (mai oltre) usando le trame di TMDB e il modello locale di Apple (già in uso per la ricerca avanzata **[C]**: `FoundationModels`). Nessuna rete verso un'AI, nessun costo.
Effetto: molto alto. Fattibilità: alta. Vincolo: qualità del modello locale su trame lunghe **[?]**; va troncato a pochi episodi.

### W2 — Sottotitoli tradotti sul dispositivo
Se non esiste il sottotitolo italiano, traduce quello inglese con il framework **Translation** di Apple, a blocchi, mentre il video parte. **[S]** (disponibile da iOS 18; richiede scaricare le lingue; l'API è pensata per SwiftUI: `translationTask`).
Effetto: alto. Fattibilità: media. Vincolo: tempi su 1.500 righe e sincronizzazione; da provare con un file vero.

### W3 — Picture in Picture anche con MPV
Oggi MPV non fa PiP **[C]**. La strada nota è disegnare i fotogrammi di MPV in un `AVSampleBufferDisplayLayer`, che è ciò che PiP richiede **[S]**.
Effetto: alto (la maggior parte dei file è MKV). Fattibilità: **bassa/da ricercare**: nessuna fonte trovata nella mia ricerca. Una prima alternativa già prevista: convertire al volo in HLS per AVPlayer (già fatto) e usare PiP lì.

### W4 — Guardare insieme (SharePlay)
`GroupActivities` + `AVPlaybackCoordinator` mantengono sincronizzati i player di Apple **[W]**. Con MPV non c'è un coordinatore: servirebbe una sincronizzazione nostra sopra `GroupSessionMessenger` (non verificata, **[W]** dice solo che non esiste un coordinatore per MPV).
Effetto: altissimo. Fattibilità: media con AVPlayer, bassa con MPV. Vincolo: il permesso "Group Activities" richiede un account di sviluppo? **[?]** e un account gratuito di SideStore potrebbe non averlo.

### W5 — Widget "Continua a guardare" e Live Activity dei download
Entrambi sono estensioni dell'app (`WidgetKit`, `ActivityKit`) **[S]**. Con SideStore ogni estensione consuma un identificativo di app dell'account gratuito (limite settimanale) **[S]** e **LiveContainer non esegue estensioni** **[S]**.
Effetto: alto. Fattibilità: media. Vincolo: dipende dal tuo uso; **verificare prima** quanti identificativi restano.

### W6 — Scorciatoie e Pulsante Azione
`AppIntents` esistono già (un file, `AetherShortcuts`) **[C]**. Estenderli: "Riprendi l'ultimo", "Cerca film simili a…" con la voce, apertura diretta di un titolo. Funzionano **senza estensione**, quindi senza limiti di sideload **[S]**.
Effetto: medio-alto. Fattibilità: alta. È il più economico dei "wow".

### W7 — Modalità notte per l'audio (MPV)
Compressione dinamica / normalizzazione (`dynaudnorm`, `acompressor`) in un tocco, per guardare di sera senza svegliare la casa **[S]** (filtri presenti in FFmpeg/MPV).
Effetto: medio, utilità alta. Fattibilità: alta. Con AVPlayer non c'è un equivalente semplice **[?]**.

### W8 — Ricerca per voce e per scena
Dettatura (`SFSpeechRecognizer`/`SpeechAnalyzer`) nella barra di ricerca avanzata: "quel film con il cane che parla e i giocattoli…". Il motore AI c'è già **[C]**.
Effetto: alto. Fattibilità: alta. Vincolo: permessi e lingua.

### W9 — Fonti "intelligenti"
Misuro (a richiesta) latenza e velocità di avvio delle prime 5 fonti (richiesta a intervalli) e propongo la migliore; ricordo cosa ha funzionato per addon e per dominio.
Effetto: medio, **utilità altissima** nell'uso quotidiano. Fattibilità: media. Vincolo: non martellare i servizi (limiti di frequenza).

### W10 — Precarica del link
A 80% di un episodio l'app già risolve il link del successivo (oggi cerca le fonti **[C]**); estendere a: risolvere anche il link debrid e aprire la connessione, così il salto è istantaneo.
Effetto: alto per chi guarda a maratone. Fattibilità: alta.

### W11 — Profili e controllo parentale
Più profili con PIN, filtro per certificazione TMDB (es. fino a 12), cronologie separate.
Effetto: medio. Fattibilità: media. Impatto: modifica del formato del backup → decidere con L10.

### W12 — Colori dal poster, ambientazione
Estrarre il colore dominante del poster per tingere sfondo e controlli (esiste già un tema grafico e Theater Mode **[C]**); effetto "Ambilight" ai bordi del video quando non riempie lo schermo.
Effetto: alto a occhio. Fattibilità: media; il bordo sfocato richiede un secondo livello di rendering sopra MPV **[?]**.

### W13 — Apple TV (tvOS)
`AetherCore` è Swift puro e riutilizzabile **[C]**; manca l'interfaccia. Esiste già la versione Android TV, quindi la parità c'è sull'altra piattaforma.
Effetto: molto alto. Fattibilità: **bassa a breve**: nuova app, MPV su tvOS, firma. Da pianificare solo dopo la stabilizzazione.

### W14 — Piccole cose che fanno "finito"
Feedback tattile coerente (`CoreHaptics` già in uso in 3 file **[C]**), suggerimenti alla prima apertura (`TipKit`), animazioni di transizione hero → scheda titolo, schermata vuota ben disegnata, "Easter egg" nuovi (esiste quello del logo **[C]**).

## 6. Vincoli del sideload da conoscere prima di costruire

- **Estensioni = identificativi**: widget, Live Activity, estensione di condivisione contano ciascuna come un'app nell'account gratuito **[S]**. Controlla il limite dell'account (di solito 3 app attive e 10 identificativi a settimana) prima di W5.
- **LiveContainer non esegue estensioni** né tutti i permessi **[S]**; in README già scritto per il PiP **[C]**.
- **Entitlement a pagamento** (CloudKit, SharePlay `group-session`, push) richiedono un account da sviluppatore **[S]**. Per questo CloudKit/iCloud non c'è e il backup è su file **[C]**.
- **Scadenza della firma**: 7 giorni con account gratuito; SideStore la rinnova da solo se è aperto **[S]**.
- **JIT / debugger**: iOS 26 è "limitato" per StikDebug **[W]**; non contarci per il debug quotidiano.

## 7. Proposta di tabella di marcia

**Stasera/domani (correzioni e basi):** i fix che hai in lista; P1.1 (segnala un problema), P1.3 (`Logger`+signpost), P1.2 (MetricKit), P1.10, P1.6; poi una build e un giro di prove con §3 blocchi A e B.
**Questa settimana:** P1.5 (CI affidabile), P1.7 (aggiornamenti), W6 (scorciatoie), W10 (precarica), P1.4 (salute delle fonti).
**Prossime due settimane:** W1 (riassunto), W7 (modalità notte), W8 (ricerca vocale), P1.8–P1.9 (notifiche e scarico automatico).
**Da valutare:** W2 (traduzione), W5 (widget, dopo il controllo dei limiti), W11, W12; W3 e W4 come ricerca; W13 solo a stabilità raggiunta.

## 8. Rischi di cui tenere conto

1. **Mole del codice non provata su dispositivo** (72k righe): ogni funzione nuova alza il debito. Ogni build si porta una lista corta di prove (come in §3), non cinquanta.
2. **Un solo sviluppatore + un solo tester** (tu): le prove sono il collo di bottiglia. Il rapporto di segnalazione (P1.1) e le build ripercorribili (source `devbuilds`) servono a questo.
3. **Dipendenze esterne** che cambiano (TMDB, IntroDB, TorBox, Trakt, Gemini): aggiungere il **controllo di stato** e messaggi chiari. Esempio già visto: modello Gemini ritirato.
4. **Rischio legale/ToS** sulle funzioni di link e debrid: restano a carico dell'uso privato; il README lo dice **[C]**.

## 9. Fonti consultate (3 novembre 2026)

- Apple, "All New Features iOS 26" (elenco ufficiale): https://www.apple.com/os/pdf/All_New_Features_iOS_26_Sept_2025.pdf
- MacRumors, annuncio iOS 26 (Liquid Glass, Live Activities): https://www.macrumors.com/2025/06/09/apple-announces-ios-26
- Blake Crosley, widget e controlli iOS 26 con App Intents (blog di terzi): https://blakecrosley.com/blog/ios-26-widget-and-control-surface
- CarPlayLife, video AirPlay in CarPlay con iOS 26: https://www.carplaylife.com/?p=45400
- Apple Developer Forums, SharePlay con controlli personalizzati: https://developer.apple.com/forums/thread/686594 e https://developer.apple.com/forums/thread/707915
- WWDC21 sessione 10225 (AVPlayer e GroupSession): https://developer.apple.com/videos/play/wwdc2021/10225/
- Guida di terzi sul `shareplay-activities`: https://openskillindex.com/skills/dpearson2699-swift-ios-skills-shareplay-activities
- Apple, `MXCrashDiagnostic` (iOS 14+): https://developer.apple.com/documentation/metrickit/mxcrashdiagnostic
- Apple Developer Forums, crash/hang non restituiti in iOS 17.2–17.5: https://developer.apple.com/forums/thread/806457
- Confronti Infuse/Plex/Stremio (siti commerciali, da prendere con cautela): https://mac.eltima.com/infuse-vs-plex/ · https://www.cloudwards.net/stremio-alternative · https://www.rapidseedbox.com/blog/stremio-vs-plex
- StikDebug / StikJIT (progetto aperto): https://github.com/StephenDev0/StikDebug · https://github.com/StikDebug/StikJIT · https://faq.altstore.io/altstore-classic/enabling-jit

**Limite della ricerca:** gli articoli trovati sono per lo più guide di terzi e confronti commerciali; per Nuvio non ho trovato recensioni, e nulla su MPV con SharePlay o PiP. Le idee W3, W4, W7 e W12 poggiano quindi su mia conoscenza **[S]** e vanno confermate con una prova di fattibilità prima di promettere.
