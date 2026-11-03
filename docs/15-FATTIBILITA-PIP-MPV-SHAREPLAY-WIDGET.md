# Fattibilità: PiP con MPV, SharePlay, widget e Live Activity

*3 novembre 2026. Voci **27, 28, 29** della lista (`14-LISTA-DA-FARE-IOS.md`). Sono **ricerche**, non funzioni: nessuna è stata costruita né provata. Etichette: **[C]** nostro codice · **[W]** fonte online (in fondo) · **[S]** conoscenza mia da verificare · **[?]** non so.*

---

## 27. Picture in Picture con MPV

**Il problema.** iOS accetta il PiP solo per i fotogrammi di `AVPlayer` o di un `AVSampleBufferDisplayLayer` **[W: documentazione Apple, `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`, iOS 15+]**. MPV disegna con Metal/Vulkan su una sua vista: per iOS il PiP non c'è **[C: il README lo dice]**.

**Tre strade**

| Strada | Come | Pro | Contro |
|---|---|---|---|
| **A. Quella che abbiamo già** | Per i MKV l'app li converte al volo in HLS e li dà ad AVPlayer, che fa il PiP **[C]** | Nessun codice nuovo | Non vale per ciò che il convertitore non gestisce (AVI, alcuni audio, ecc.); dipende dall'impostazione «Converti MKV per AVPlayer» **[C]** |
| **B. Un fork di MPV con uscita video AVFoundation** | Il fork di Alex Kovalenko/streamyfin aggiunge `vo_avfoundation` che disegna in un `AVSampleBufferDisplayLayer`, con PiP, VideoToolbox, HDR e Dolby Vision **[W]** | È già fatto | **È la variante `MPVKit-GPL`** **[W]**: rende l'intera app GPL. Il nostro `docs/03-LICENSES.md` esclude proprio quella variante **[C]**; incompatibile con una futura strada TestFlight/App Store. Nessuna licenza dichiarata nella pagina del rilascio **[W]** |
| **C. Scrivere noi il ponte** | Usare l'API di render software di libmpv, copiare i fotogrammi in `CVPixelBuffer` → `CMSampleBuffer` → `AVSampleBufferDisplayLayer` **[S]** | Resta LGPL | Lavoro grosso (settimane), costo di CPU/energia, niente HDR/Dolby Vision, sincronismo audio/video da governare, nessun riferimento trovato online **[?]** |

**Verdetto.** Prima si **prova la strada A** (voci 7 e 20 della lista delle prove): con MKV convertiti, il PiP dovrebbe già andare. Se funziona, il PiP per MPV non serve a quasi nessuno. B è da **escludere** per licenza. C solo se A non basta, e solo dopo una misura reale.

**Prova da fare tu (10 minuti):** MKV con motore Automatico + conversione attiva → apri il player → vai alla Home: deve comparire il PiP. Poi un AVI (resta in MPV): ci si aspetta il messaggio onesto che spiega perché non c'è PiP.

---

## 28. SharePlay («guardare insieme»)

**Come funziona in iOS.** `GroupActivities`: un'attività condivisa in una chiamata FaceTime, con il bottone SharePlay del foglio di condivisione **[W]**. Per un lettore con `AVPlayer` il sistema sincronizza play, pausa e posizione con `AVPlaybackCoordinator` **[W]**: va collegato quando si crea il lettore, con la sessione ricevuta dall'attività; con controlli personalizzati sopra `AVPlayer` l'integrazione ha dato problemi segnalati dagli sviluppatori **[W: forum Apple]**.

**Tre ostacoli**
1. **Entitlement.** Serve `com.apple.developer.group-session` (capability «Group Activities» legata all'App ID) **[W]**. Non ho trovato nessuna fonte che dica se un **account gratuito** (SideStore) può usarla **[?]** — probabilmente no, perché molte capability richiedono il programma a pagamento **[S]**.
2. **MPV.** Non ha un `AVPlaybackCoordinator`. Servirebbe una sincronizzazione nostra sopra `GroupSessionMessenger` (messaggi di play/pausa/posizione ogni pochi secondi) **[S]**.
3. **Fonti diverse.** Ognuno deve avere accesso allo stesso link: con debrid e account personali è un problema. Il link di uno non vale per l'altro (credenziali) **[C]**. L'attività dovrebbe portare il **titolo** (id del titolo e dell'episodio) e ognuno risolve la sua fonte.

**Alternative senza entitlement:** *«Guarda insieme qui vicino»* con `MultipeerConnectivity` (stessa rete Wi-Fi, nessun server, nessuna capability) **[S]**; solo un amico accanto a te.

**Prova di fattibilità (la sola che conta):** una build con `com.apple.developer.group-session` nel file di entitlement e l'installazione con SideStore. Se SideStore la installa e il bottone SharePlay compare, il resto è lavoro nostro; se rifiuta o toglie l'entitlement, la strada è chiusa. **Costo della prova: circa un'ora; io preparo la build, tu la installi.**

**Verdetto.** Non partire prima di questa prova. Se l'entitlement c'è: AVPlayer sì (medio), MPV no (lavoro grosso e fragile).

---

## 29. Widget «Continua a guardare» e Live Activity dei download

**Cosa servirebbe.** Un'estensione WidgetKit (i widget e le Live Activity stanno nella stessa estensione), con i dati condivisi con l'app tramite App Group **[S]**.

**Vincoli di SideStore con l'account gratuito [W]**
- **10 App ID** registrabili e validi 7 giorni; ogni app ne usa **uno più uno per estensione** **[W: FAQ di AltStore]**. Aether oggi ne usa **1** **[C]**: con l'estensione dei widget diventano **2**; con anche un'estensione di condivisione **3**.
- **3 app attive** al massimo sul telefono **[W]**: se ne hai già altre, il conto è già pieno.
- Widget, tastiere e altre estensioni possono **non funzionare** con la firma gratuita **[W: note di uno strumento di terzi]**: nessuna conferma per le Live Activity **[?]**.
- L'**App Group** per passare i dati all'estensione: non so se SideStore lo registra per un account gratuito **[?]**.
- **LiveContainer non esegue estensioni** **[S]**.

**Da sapere sulle Live Activity.** Si possono avviare e aggiornare dall'app in locale (`ActivityKit`), senza server; gli aggiornamenti remoti richiedono notifiche push (a pagamento) **[S]**. Per un download in corso (l'app è in primo piano o in background breve) il valore è basso: l'app non viene tenuta viva quando è in background.

**Prova di fattibilità:** un'app minima con estensione widget e App Group, installata con SideStore: se il widget compare e legge un valore scritto dall'app, la strada è aperta. **Costo: mezza giornata (io); tu installi e mi dici se compare.**

**Verdetto.** Il widget «Continua a guardare» è la parte utile; la Live Activity dei download quasi no. Prima la prova, **poi** si decide. Controlla anche quante app hai già sul telefono con SideStore.

---

## Fonti
- Apple: `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` (iOS 15+) e WWDC21 sessione 10290.
- Fork `streamyfin/MPVKit` rilascio `0.40.0-av` (uscita video AVFoundation, PiP, prodotto `MPVKit-GPL`): https://github.com/Alexk2309/MPVKit/releases/tag/0.40.0-av
- Apple, `com.apple.developer.group-session` e «Configuring Group Activities».
- Forum Apple: https://developer.apple.com/forums/thread/686594 · https://developer.apple.com/forums/thread/707915 · WWDC21 sessione 10225.
- FAQ di AltStore sugli App ID: https://faq.altstore.io/altstore-classic/app-ids
- Note di iPASide (limite di 3 app, estensioni con firma gratuita): https://newreleases.io/project/github/pwnapplehat/iPASide/release/v1.1.0

**Limiti di questa ricerca.** Per tutte e tre le voci non esiste una fonte che risponda alla domanda decisiva (cosa permette un account gratuito). Le conclusioni vere arrivano dalle prove indicate.
