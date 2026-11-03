# Lista da fare per iOS (spunte a mano a mano)

Numerazione = quella scelta il 3/11/2026 (da `12-ANALISI-PER-IOS.md`). ✅ fatto e compilato in CI · 🟡 scritto, **non provato su iPhone** · ☐ da fare.
Priorità: build e CI veloci e affidabili, poi le funzioni. Le funzioni nuove hanno un interruttore nelle impostazioni dove ha senso.

## Infrastruttura (priorità massima)
- ✅ **6** Swift nella sandbox: `swift test` del Core in locale
- ✅ **12** CI veloce e affidabile (UI test solo su richiesta, timeout, nuovi tentativi, Core su Linux, screenshot dei fallimenti)
- 🟡 **10** dSYM allegati alla release `devbuilds` per ogni build
- ☐ **11** Note "cosa c'è di nuovo" per area + foglio in app che le legge

## Correzioni
- ☐ **1** Log dei tempi della ricerca avanzata senza righe vuote
- ☐ **3** Badge "Stagione completa" sulle fonti pack
- ☐ **4** Episodi scaricati segnati nella lista episodi
- ☐ **5** Download web/usenet di TorBox nella scheda Cloud

## Funzioni (con interruttore dove indicato)
- ☐ **15** Precarica del link del prossimo episodio (interruttore)
- ☐ **17** Notifiche "nuovo episodio" con il calendario Trakt (interruttore)
- ☐ **18** Controllo aggiornamenti dalla source di SideStore (interruttore)
- ☐ **19** Scorciatoie e Pulsante Azione (App Intents)
- ☐ **21** Sottotitoli tradotti sul telefono (interruttore)
- ☐ **24** Colori dal poster per tingere l'interfaccia (interruttore)

## Ricerche di fattibilità (documento, nessuna promessa)
- ☐ **27** Picture in Picture con MPV
- ☐ **28** SharePlay ("guardare insieme")
- ☐ **29** Widget e Live Activity (limiti del sideload)

## Alla fine
- ☐ Build e CI, release `devbuilds` / source SideStore
- ☐ Elenco delle novità e lista delle prove

## Registro delle verifiche
- **6** — Swift 6.0.3 installato in `~/swift-tc`; `Scripts/test-core.sh` esegue 904 test del Core in ~7 s (16 saltati su Linux perché richiedono Apple). Compilazione su Linux sistemata (`waitsForConnectivity`, `FoundationNetworking` nei test, un'espressione troppo complessa, due blocchi NSLock in contesti async).
- **12** — CI: nuovo lavoro `core-linux` (container Swift, ~2 min); UI test solo su `main` o con `ui_tests` esplicito (prima ogni avvio manuale li eseguiva tutti, ~15+ min e a volte si bloccavano); timeout per test (120/300 s), un nuovo tentativo, timeout di 40 min sul passaggio. Da verificare alla prima esecuzione reale.
- **10** — dSYM dell'archivio zippati, caricati come artefatto e allegati alla release `devbuilds` (`Aether-devbuild-N.dSYM.zip`). Da verificare alla prima build.
