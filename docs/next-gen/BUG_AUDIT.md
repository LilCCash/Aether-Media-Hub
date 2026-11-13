# Audit dei bug

Base: `aether-swift-features` @ `b9920db`. Priorità: P0 perdita dati/sicurezza critica/crash sistematico · P1 grave ·
P2 correttezza/affidabilità · P3 minore. Tabella sintetica in [`bugs.csv`](bugs.csv).

## BUG-01 — ConcurrencyLimiter: i task annullati restano in coda · P2 · **Confermato → corretto**
- **File:** `Packages/AetherCore/Sources/AetherCore/Util/ConcurrencyLimiter.swift` (`acquire`, `withPermit`).
- **Prima:** `withCheckedContinuation` senza gestore di annullamento; il task annullato aspettava il turno e poi
  eseguiva comunque l'operazione.
- **Scenario:** scorrimento rapido tra schermate con 20+ cataloghi → decine di richieste inutili davanti a quelle nuove.
- **Correzione:** waiter con id, `withTaskCancellationHandler` che li rimuove subito (l'annullamento arriva sull'actor
  dopo la registrazione, quindi non c'è corsa); permesso restituito se l'annullamento arriva insieme al permesso;
  `maxWait` opzionale con timer annullato alla consegna.
- **Test:** `ReliabilityFixTests` (200 waiter annullati, timeout in coda, 60 task misti con limite 2; nessun permesso perso).

## BUG-02 — AddonService: la scadenza non include l'attesa in coda · P2 · **Confermato → corretto**
- **File:** `Addons/AddonService.swift` `perform(_:path:mode:)`.
- **Prima:** `limiter.withPermit { withDeadline(timeout + 1) { … } }`: in coda nessun limite.
- **Scelta:** spostare tutto sotto un'unica scadenza da 16 s avrebbe fatto fallire richieste legittime nelle raffiche
  (Home con molti cataloghi): sarebbe una perdita di funzionalità. L'attesa in coda è limitata a 2× timeout
  (30 s), quindi il caso peggiore è 3× timeout + 1 s ed è sempre finito.
- **Test:** `testQueueWaitIsBoundedByMaxWait`.

## BUG-03 — LiveRemux: thread FFmpeg non chiuso all'annullamento · P1 secondo l'audit esterno · **Non confermato** (irrobustito)
- **File:** `Services/Remux/LiveRemux.swift` `start(timeout:)`.
- **Verifica:** `try Task.checkCancellation()` e `Task.sleep` lanciano senza `close()`, ma l'unico chiamante
  (`LocalRemuxService.swift:279-284`) chiude il motore in ogni `catch`. Nessun thread orfano.
- **Irrobustimento:** `start()` chiude da solo su ogni uscita non riuscita (difesa per chiamanti futuri).

## BUG-04 — ResponseCache: nessun budget in byte, disco mai potato · P2 · **Confermato → corretto**
- **Prima:** 400 voci in memoria senza limite di dimensione (teorico 400 × 8 MiB), disco senza limite né pulizia
  automatica, file corrotti riletti a ogni ricerca.
- **Correzione:** 48 MiB in memoria (voce più grande del budget → solo disco), 256 MiB su disco con eliminazione LRU
  per data di modifica (aggiornata a ogni lettura) fino al 90%, file non usati da 30 giorni eliminati (più di ogni
  finestra stale predefinita: il comportamento offline resta), file corrotti cancellati, disco pieno → solo memoria.
- **Test:** `testMemoryByteBudgetEvictsLeastRecentlyUsed`, `testDiskBudgetAndAgeArePruned`, `testCorruptDiskEntryIsRemovedAndTreatedAsMiss`
  + test esistenti di persistenza e stale.

## BUG-05 — HTTPClient: `cancelled`/`failure` letti fuori dal lock · P2 · **Confermato (statico) → corretto**
- **File:** `Net/HTTPClient.swift` `urlSession(_:task:didCompleteWithError:)`.
- **Correzione:** letti nella stessa sezione critica che toglie la richiesta dalla tabella; `RequestState` dichiarato
  `@unchecked Sendable` con nota sul lock.
- **Verifica:** Thread Sanitizer su tutta la suite Core (1063 test): 0 avvisi.

## BUG-06 — ImageLoader: file in cache corrotto → segnaposto fino alla visita dopo · P3 · **Confermato → corretto**
- **Correzione:** eliminazione e un solo nuovo download nella stessa chiamata (il secondo tentativo non legge il disco,
  quindi nessun ciclo).
- **Test:** `testCorruptCachedFileIsRefetchedInTheSameCall`, `testUndecodableDownloadIsNotRetriedForever`.

## NEW-01 — Relay HLS: MIME mancanti per rendition audio/sottotitoli · P3 · **Corretto**
- **File:** `Services/Relay/AdaptiveStreamRelaySource.swift` `mimeType(for:)`.
- `m4a`, `ac3`, `ec3`, `webvtt`, `ttml/dfxp`, CMAF uscivano come `application/octet-stream`. Alcuni ricevitori
  ignorano il tipo dei segmenti, altri no.
- **Test:** `AdaptiveRelayHLSTests` (5 test: attributi `EXT-X-MEDIA` intatti, URI risolti con query firmata, segmenti
  WebVTT, deduplicazione, playlist cifrate rifiutate senza esporre URL).

## NEW-02 — ResponseCache: `touch` su voci non in memoria · P3 · **Corretto** insieme a BUG-04
L'ordine LRU poteva contenere chiavi senza voce. Ora `touch` avviene solo se la voce è in memoria.

## NEW-03 — Pulsante «…» del player senza etichetta di accessibilità · P2 · **Corretto** (preesistente)
- **File:** `Features/Player/PlayerMoreMenu.swift`. VoiceOver leggeva il nome dell'icona; trovato dal test UI
  `testPlayerControlsHaveAccessibilityLabels`, che falliva già sul codice di base. Ora «Altre opzioni».

## NEW-04 — Test UI del Casting con selettore sbagliato · P3 · **Corretto** (preesistente)
- `testCastingScreenExplainsWhatIsAvailable` cercava «DLNA / UPnP» come testo statico, ma è un interruttore (dal 19/10).
  Il test ora cerca interruttori o testi che iniziano con «Google Cast»/«DLNA»; l'asserzione resta la stessa.

## Fallimenti preesistenti nei test UI (non corretti, fuori dall'ambito)
Verificati sul branch di base `b9920db` con la stessa selezione di test (run 43453573172): stessi test, stessi messaggi.
| ID | Test | Sintomo | Causa probabile |
|---|---|---|---|
| PRE-01 | MetadataUITests ×5 | `service.tmdb.key missing` | Il campo non ha più quell'identificatore nell'app (nessun `service.tmdb.key` nel codice): test da allineare alla pagina Servizi attuale |
| PRE-02 | TorBoxUITests ×5 (cached, not cached, season pack, wrong key, stop wait) | «the player did not open / picker error», stato non mostrato | Flusso debrid del fixture non più allineato all'app; da indagare con il bundle `.xcresult` |
| PRE-03 | HomeCustomization `testChoosingWideCards…` | anteprima di installazione addon non comparsa (1 volta su 3) | Instabile (tempi del fixture) |

## Rischi statici non confermati (da verificare su dispositivo)
| ID | Descrizione | Perché non confermato |
|---|---|---|
| RISK-01 | `URLSessionHTTPClient` redirect: `Task` che cattura `completionHandler` (unico avviso Swift 6 rimasto nel Core) | URLSession accetta il completion da qualsiasi thread; nessun accesso a stato condiviso |
| RISK-02 | Molti `Task {}` nelle View senza annullamento esplicito | `.task` di SwiftUI li annulla; non trovato un caso concreto |
| RISK-03 | Sync iCloud: conflitti tra due dispositivi | richiede due dispositivi |
