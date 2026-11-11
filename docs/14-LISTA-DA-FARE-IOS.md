# Lista da fare per iOS (spunte a mano a mano)

Numerazione = quella scelta il 3/11/2026 (da `12-ANALISI-PER-IOS.md`). ✅ fatto e compilato in CI · 🟡 scritto, **non provato su iPhone** · ☐ da fare.
Priorità: build e CI veloci e affidabili, poi le funzioni. Le funzioni nuove hanno un interruttore nelle impostazioni dove ha senso.

## Aether 2.0 (11/11/2026)
- 🟡 **1** Documenti, README e note allineati alla versione 2.0
- 🟡 **2** Pannello tecnico «In tempo reale» nel player
- 🟡 **3** Doppi sottotitoli
- 🟡 **4** Avviso quando un salvataggio non riesce, con nuovo tentativo
- 🟡 **5** Logger, signpost e MetricKit nel registro diagnostico
- 🟡 **6** Sottotitoli salvati con i download
- 🟡 **7** «Dove eravamo rimasti?» (Apple Intelligence)
- 🟡 **8** Punteggio delle sorgenti con il perché
- 🟡 **9** Siri: aggiungi alla watchlist, apri la scheda
- 🟡 **10** Widget: riprendi, watchlist, apri la scheda
- 🟡 **11** Guida TV (XMLTV) per le playlist M3U
- 🟡 **12** Prossimo titolo evidenziato nella mappa degli universi
- ✅ **18** `PlayerViewModel` e lista sorgenti divisi in file
- 🟡 **P** Pulizia grafica, personalizzazioni sistemate in chiaro e scuro, animazioni con interruttore

## Infrastruttura (priorità massima)
- ✅ **6** Swift nella sandbox: `swift test` del Core in locale
- ✅ **12** CI veloce e affidabile (UI test solo su richiesta, timeout, nuovi tentativi, Core su Linux, screenshot dei fallimenti)
- 🟡 **10** dSYM allegati alla release `devbuilds` per ogni build
- 🟡 **11** Note "cosa c'è di nuovo" per area + foglio in app che le legge

## Correzioni
- 🟡 **1** Log dei tempi della ricerca avanzata senza righe vuote
- 🟡 **3** Badge "Stagione completa" sulle fonti pack
- 🟡 **4** Episodi scaricati segnati nella lista episodi
- 🟡 **5** Download web/usenet di TorBox nella scheda Cloud

## Funzioni (con interruttore dove indicato)
- 🟡 **15** Precarica del link del prossimo episodio (interruttore)
- 🟡 **17** Notifiche "nuovo episodio" con il calendario Trakt (interruttore)
- 🟡 **18** Controllo aggiornamenti dalla source di SideStore (interruttore)
- 🟡 **19** Scorciatoie e Pulsante Azione (App Intents)
- 🟡 **21** Sottotitoli tradotti sul telefono (interruttore)
- 🟡 **24** Colori dal poster per tingere l'interfaccia (interruttore)

## Ricerche di fattibilità (documento, nessuna promessa)
- ✅ **27** Picture in Picture con MPV → `15-FATTIBILITA-PIP-MPV-SHAREPLAY-WIDGET.md`
- ✅ **28** SharePlay ("guardare insieme")
- ✅ **29** Widget e Live Activity (limiti del sideload)

## Alla fine
- ☐ Build e CI, release `devbuilds` / source SideStore
- ☐ Elenco delle novità e lista delle prove

## Registro delle verifiche
- **6** — Swift 6.0.3 installato in `~/swift-tc`; `Scripts/test-core.sh` esegue 904 test del Core in ~7 s (16 saltati su Linux perché richiedono Apple). Compilazione su Linux sistemata (`waitsForConnectivity`, `FoundationNetworking` nei test, un'espressione troppo complessa, due blocchi NSLock in contesti async).
- **12** — CI: nuovo lavoro `core-linux` (container Swift, ~2 min); UI test solo su `main` o con `ui_tests` esplicito (prima ogni avvio manuale li eseguiva tutti, ~15+ min e a volte si bloccavano); timeout per test (120/300 s), un nuovo tentativo, timeout di 40 min sul passaggio. Da verificare alla prima esecuzione reale.
- **10** — dSYM dell'archivio zippati, caricati come artefatto e allegati alla release `devbuilds` (`Aether-devbuild-N.dSYM.zip`). Da verificare alla prima build.
- **Prima esecuzione reale della CI nuova (build 137):** il lavoro Linux ha trovato un mio errore (la shell del container non conosce `pipefail`, corretto con `shell: bash`); compilazione dell'app e test dell'app verdi; un test del Remux (`testAFailingPieceIsAnErrorForThatPieceOnly`) è fallito una volta sul Mac, non su Linux né in 6 prove locali: l'ho reso tollerante all'ordine dei tempi.
- **10, 11** — verificati: la build 137 ha pubblicato `Aether-devbuild-137.dSYM.zip` e le note nella source.
- **Funzioni 15, 17, 18, 19, 21, 24:** scritte e compilate in CI, **non provate su iPhone**.

## Widget, Live Activity, SharePlay, notifiche (5 novembre 2026)
- 🟡 **Widget «Continua a guardare»** (`App/AetherWidgets`, dati in App Group) — scritto, compilato in CI, **non provato su iPhone**.
- 🟡 **Live Activity dei download** (ActivityKit) — scritta e compilata; si aggiorna solo quando l'app gira.
- 🟡 **SharePlay «Guarda insieme»** (GroupActivities, sincronizzazione nostra di play/pausa/posizione) — scritto e compilato; dipende dall'entitlement che SideStore potrebbe togliere.
- 🟡 **Notifiche:** nuovi episodi (Trakt) e fine dei download — scritte e compilate.
- La build `138` porta tutto: il pacchetto contiene l'estensione `AetherWidgets.appex` e gli entitlement (App Group e SharePlay) con firma ad-hoc, che SideStore sostituisce con la sua.

## Novembre 2026 · seconda tornata
- 🟡 Profilo (foto, generi), gioco dei gusti, voti modificabili, inviti con consigli per genere
- 🟡 Libreria: scelta tra lista Aether e lista Trakt (quando la sincronizzazione unita è spenta)
- 🟡 Trailer dentro l'app
- 🟡 Citazioni rinnovate, widget piccoli sistemati, formato grande per tutti i widget
- ☐ PiP con MPV: non implementato (serve il rendering software di libmpv su AVSampleBufferDisplayLayer; vedi `15-FATTIBILITA-PIP-MPV-SHAREPLAY-WIDGET.md`)
