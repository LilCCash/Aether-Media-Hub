# Bugfixing per iOS — metodi più veloci per noi

*3 novembre 2026. Compagno di [12-ANALISI-PER-IOS.md](12-ANALISI-PER-IOS.md). Etichette: **[C]** nostro codice/log · **[W]** fonte online (§12) · **[S]** conoscenza mia da verificare · **[?]** non so.*

**Il nostro vincolo.** Sviluppo in un ambiente **senza Mac e senza Swift locale** (`swift` non c'è nella sandbox **[C]**); le prove avvengono sul **tuo iPhone** (build sideloaded) e in **CI su macOS**. Il bugfixing veloce qui significa **ridurre il giro** "bug → causa → correzione → prova", non usare Xcode.

---

## 1. Dove si perde tempo oggi (misurato su questa sessione)

| Spreco | Esempio reale | Costo |
|---|---|---|
| Capire il contesto di un errore | Trakt -1005: 4 scambi per scoprire il codice vero | giorni |
| Compilare solo in CI | Test sbagliati e `Codable` mancante scoperti dopo una build da ~8 minuti, tre volte (`hdrPhone`, `PackFiles`, `ExternalPlayer`) **[C]** | 3 build |
| CI che non finisce | UI test fermo oltre 1 ora, CI annullate **[C]** | attese lunghe |
| Provare tutto a mano | Lista di 23 prove per ogni build | tuo tempo |
| Bug senza dati | 403 sui canali: mi mancano nome canale + messaggio + log **[C]** | in sospeso |

## 2. La regola base: ogni bug deve nascere con quattro dati

1. **Numero di build** (dall'app o da SideStore, es. 135) e **commit**.
2. **Passi** per riprodurlo e **esito atteso vs ottenuto**.
3. **Log dell'app** (Impostazioni ▸ Diagnostica) **subito dopo** il problema, non il giorno dopo (il log ruota).
4. **Schermata o video** se è grafica/gesti.

Il pulsante **"Segnala un problema"** (P1.1 in 12-ANALISI) li raccoglie da solo: è il singolo intervento che accorcia di più il giro.

## 3. Strumenti per ordine di velocità

### 3.1 Log dell'app (già c'è, va potenziato) **[C]**
`DiagnosticLog` con `Redactor` (toglie token e chiavi). Mancano: livelli coerenti, categorie per area (player, debrid, download, trakt, ricerca), **tempi**.
**Fare:** categorie fisse e un "rapporto" esportabile (§2).

### 3.2 `os.Logger` + signpost (nessuno oggi **[C]**)
`Logger(subsystem:category:)` è l'approccio consigliato al posto di `print` **[W]**; `OSSignposter` segna intervalli visibili in Instruments **[W]**.
Beneficio: gli strumenti di Apple (e la Console di un Mac, se mai ne userai uno) leggono l'app.
**Fare:** un wrapper unico che scrive in `DiagnosticLog` **e** in `Logger`; signpost su: apertura sorgente, risoluzione debrid, avvio motore, prima immagine, ricerca, download.

### 3.3 MetricKit: crash e hang riportati dall'app stessa
`MXCrashDiagnostic` (tipo di eccezione, segnale, stack) e `MXHangDiagnostic` arrivano all'app, dal giorno dopo, con `MXMetricManager` **[W]**. Gli stack vanno **simbolicati fuori dal dispositivo**: servono gli UUID dei binari e gli indirizzi di caricamento che MetricKit fornisce **[W]**.
Limiti: su iOS 17.2–17.5 le diagnostiche **non** venivano consegnate al lancio successivo **[W]**; per app sideloaded non ho fonti **[?]**.
**Fare:** abbonarsi, salvare i JSON in una cartella, mostrarli in "Diagnostica" e allegarli al rapporto.

### 3.4 Crash log di sistema dal telefono, senza Mac
- **Impostazioni ▸ Privacy e sicurezza ▸ Analisi e miglioramenti ▸ Dati di analisi**: lì stanno i file `.ips` di ogni crash di app, se l'analisi è attiva **[S]**.
- **sysdiagnose**: gesto di tasti (volume su + volume giù + tasto laterale, 1-2 secondi), il file compare in Analisi **[S]**. Pesante ma completo.
Entrambi sono copiabili con "Condividi" e mandabili a me.
**Fare:** una riga in "Cosa mi serve" (docs/11) con questi due percorsi.

### 3.5 Simbolicazione: servono gli **stessi** simboli della build
Un crash non si legge senza i file `.dSYM` esatti **[W]**. LLDB li usa meglio dei sistemi di raccolta **[W]**.
**Fare (alto valore, basso costo):** il workflow di build allega il `.dSYM` (cartella `dSYMs` dell'archivio) alla release `devbuilds` accanto all'IPA, con lo stesso numero di build. Senza questo un crash di una build vecchia è illeggibile.

### 3.6 Debugger sul telefono senza Mac
**StikDebug / StikJIT** attacca un debugger al processo da un altro processo sul telefono, usa un file di abbinamento creato una volta su un computer, e una VPN di loopback **[W]**; ha una console per i log live **[W]**. iOS 26 è dato come **supporto limitato** **[W]**; non è più nell'App Store **[W]**.
Per noi: utile **a una persona che ha accesso a un computer una volta**; non è il nostro canale di tutti i giorni.

### 3.7 Debug su dispositivo con Mac (se mai ne avrai uno)
Memory Graph, Thread Checker, Instruments (Time Profiler, Hitches, Leaks, Allocations filtrati per nostro modulo) **[W]**; `idevicesyslog` (libimobiledevice) per i log via cavo **[S]**. Non necessario ora.

## 4. Accorciare il giro: l'officina in CI

### 4.1 Compilare in secondi: `swift test` per il Core
`AetherCore` è Swift puro **[C]** e gira su Linux. Se installo una toolchain Swift nella sandbox (via `swiftly`/archivio ufficiale **[?]** da provare con la rete a disposizione), i test del Core girano **in locale in pochi minuti la prima volta e secondi dopo**, invece degli 8+ minuti di CI.
È il **miglior acceleratore possibile**: tutti e tre i fallimenti di compilazione di oggi erano nel Core o nei suoi test.
**Fare:** tentativo di installazione, poi `Scripts/swift_syntax_check.py` + `swift test` prima di ogni push.

### 4.2 CI solo dove serve
- Il flusso `ci.yml` ha due lavori: Core (veloce) e App (lento). Dare priorità al Core a ogni push; app + UI solo su richiesta o su ramo principale.
- **Timeout per test** e `-retry-tests-on-failure` per i test UI instabili; ora un test che si blocca tiene un'ora la CI **[C]**.
- **Artefatto con screenshot e `.xcresult`** a ogni fallimento: mi permette di vedere cosa vede il simulatore senza rilanciare.
- Cache di SwiftPM già presente **[C]**; cache di `DerivedData` da valutare **[?]**.

### 4.3 Test al posto delle prove a mano
Ogni bug corretto diventa un test **prima o insieme** al fix (già fatto con `ContainerSniffer`, `LiveContainerLauncher`, `DownloadItem`). Per il player abbiamo un **server fixture** (`Tools/FixtureAddonServer`, `FixtureTorBoxServer`) e un video di prova generato (`MakeFixtureVideo.swift`) **[C]**: i flussi dall'addon al player si provano in simulatore senza rete.

### 4.4 Bisezione con la source SideStore
Ora ogni build è scaricabile dal numero (release `devbuilds`). Quando qualcosa "prima funzionava": installa build N, N/2…; trovi la build in cui si rompe in 3-4 tentativi. La nota "cosa è nuovo" di ogni build restringe il campo.
**Fare:** aggiornare `docs/devbuild-notes.md` prima di ogni build con un elenco **per area** (non per commit).

### 4.5 Interruttori di funzione (feature flag)
Un pannello "Sperimentale" (già esiste "Avanzate/Diagnostica" **[C]**) con interruttori per le funzioni nuove: se una build si rompe a causa di una funzione, la spegni senza aspettare un'altra build.

## 5. Procedura per classe di bug

| Classe | Primo passo | Dati che servono | Spesso è… |
|---|---|---|---|
| **Crash all'avvio** | Dati di analisi (§3.4) + MetricKit | file `.ips`, build | impostazioni non decodificabili dopo un aggiornamento |
| **Errore di rete (-1003/-1004/-1005/-1200)** | Codice nel messaggio | codice, host, rete (Wi-Fi/5G) | DNS, TLS, connessione riutilizzata scaduta (Trakt -1005 **[C]**) |
| **Player non parte** | Pannello errore + log motore | formato file, motore scelto | estensione sbagliata (MKV in `.mp4`, già corretto), codec non supportato |
| **Tocco che non risponde** | Registro apertura/chiusura del player | cosa stava accadendo (errore appena aperto?) | trasizione UIKit ancora in corso, richiesta ignorata (già gestita con ritentativi) |
| **Download fallito** | Log "downloader" | HTTP, tipo, byte, anteprima (già registrati **[C]**) | link scaduto, risposta HTML |
| **Debrid** | Messaggio + stato | servizio, in cache o no | credenziali, limiti, non in cache |
| **Ricerca AI** | Log tempi | fornitore, modello, risposta | modello ritirato (visto con Gemini **[C]**) |
| **Grafica** | Screenshot + modello iPhone + tema | orientamento, testo grande | layout con Dynamic Type |
| **Lento** | Signpost (§3.2) | quale fase | rete, non CPU |

## 6. Checklist prima di ogni push (per me)

1. `Scripts/swift_syntax_check.py` sui file toccati **[C]** (ha un falso positivo noto in `PlayerViewModel.swift`).
2. `swift test --filter` dei test nuovi (quando §4.1 è pronto).
3. Ogni tipo `Codable` nuovo: tutti i campi `Codable` (errore vero di oggi: `ExternalPlayer`).
4. Ogni nuovo test: in **una** classe, con i suoi helper (errore di oggi: `hdrPhone`).
5. Messaggi di commit con `[skip ci]` quando non voglio costruire; mai la frase letterale altrove **[C]**.
6. Una build ogni cluster di modifiche, non ogni modifica.

## 7. Registro dei bug emersi (questa sessione)

| # | Sintomo | Causa trovata | Stato |
|---|---|---|---|
| B1 | Trakt "server non risponde", poi -1005 | connessione riutilizzata scaduta / sessione condivisa; tentativi e sessione dedicata | **funziona** (confermato) |
| B2 | Cataloghi live StreamViX assenti in Discover | extra `genre` obbligatorio | corretto, da riprovare |
| B3 | Live con AVPlayer | convertito/remux inutile | motore live a parte, da riprovare |
| B4 | Gemini "google non risponde" | modello ritirato per i nuovi utenti | messaggi chiari; default da aggiornare (L13) |
| B5 | Pulsante "Chiudi" nell'errore a volte non risponde | dismiss ignorato se la pagina si muove | ritentativi dopo il tocco · **da provare** |
| B6 | Download con AVPlayer in errore | file MKV con nome `.mp4` (ipotesi) | riconoscimento dal contenuto · **da provare**; se persiste serve messaggio e formato |
| B7 | Episodio successivo cerca sorgente anche se scaricato | nessuna regola "scaricato per primo" | impostazione aggiunta · **da provare** |
| B8 | Intro non disponibile offline | dati solo online | salvati con il download · **da provare** |
| B9 | CI: test sbagliato nel posto sbagliato / `Codable` mancante / testo `.txt` contato come video | errori miei | corretti nei commit `713474b`, `ec980f5`, `920c403` |
| B10 | CI UI test fermo per oltre 1 ora | non indagato | **aperto** (L4) |
| B11 | Run "Build IPA #134" senza build, numero consumato | ripubblicazione della 133 | evitato in futuro |
| B12 | SideStore "versione scaricata diversa" | versione nella source ≠ versione nell'IPA | corretto (versione reale + build nel campo build) |
| B13 | Canali 403 | geolock/ referer | **aperto** (servono dati) |
| B14 | `ExternalPlayer` non `Codable` | errore mio | corretto |

## 8. Piano immediato (nell'ordine in cui lo farei)

1. **Toolchain Swift nella sandbox** (§4.1) — il cambio più grande per la velocità.
2. **P1.1 "Segnala un problema"** + **P1.3 `Logger`/signpost** + **P1.2 MetricKit**.
3. **dSYM nella release** (§3.5) e **`docs/devbuild-notes.md` per area** (§4.4).
4. **CI**: timeout, retry, artefatti schermata (§4.2).
5. Correzioni di L13 e i tuoi aggiustamenti di stasera/domani.

## 9. Come mi mandi un bug (modello da copiare)

```
Build: 135
Dove: Player › dopo aver aperto un episodio scaricato
Passi: 1) … 2) … 3) …
Atteso: …
Ottenuto: …
Frequenza: sempre / a volte / una volta
Rete: Wi-Fi / dati / offline     Motore: Automatico / AVPlayer / MPV
Allegati: rapporto (Segnala un problema) o log + schermata
```

## 10. Cosa NON conviene fare

- Aspettare più build per correggere più bug insieme **quando il Core non compila**: un solo errore blocca tutto.
- Scrivere correzioni "difensive" senza causa: a volte aggiungono ritardi (es. attesa fissa).
- Ignorare un messaggio con codice: **il codice è il dato**.
- Contare sul debugger sul telefono (§3.6) finché non è provato su iOS 26.

## 11. Dubbi onesti

- **MetricKit su sideload**: l'API è la stessa **[W]**, il comportamento reale è **[?]**.
- **Percorsi dei menu di iOS** (§3.4): descritti a memoria **[S]**, possono avere altre etichette in italiano.
- **Installazione di Swift nella sandbox**: dipende dalla rete e dallo spazio **[?]**.
- **Il consiglio sulle CI** nasce da questa sessione, non da una prova su altre configurazioni.

## 12. Fonti (3 novembre 2026)

- Guida a Instruments, Memory Graph, Thread Checker, `OSSignposter`, `Logger`: https://skills.sh/dpearson2699/swift-ios-skills/debugging-instruments
- Guardsquare, simbolicare i crash report con LLDB: https://www.guardsquare.com/blog/making-the-most-out-of-ios-crash-reports-with-lldb
- Apple Developer Forums, simbolicazione di MetricKit (UUID e indirizzi di caricamento): https://developer.apple.com/forums/thread/829530
- Apple, `MXCrashDiagnostic`: https://developer.apple.com/documentation/metrickit/mxcrashdiagnostic
- Apple Developer Forums, diagnostiche non restituite in iOS 17.2–17.5: https://developer.apple.com/forums/thread/806457
- StikDebug / StikJIT e FAQ di AltStore su JIT: https://github.com/StephenDev0/StikDebug · https://github.com/StikDebug/StikJIT · https://faq.altstore.io/altstore-classic/enabling-jit
- Forum Ray Wenderlich, simboli per i crash log: https://forums.raywenderlich.com/t/debugging-app-on-device/28441
