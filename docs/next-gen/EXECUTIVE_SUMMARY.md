# Executive summary

## Fatto in questo branch
| Area | Modifica | Verifica |
|---|---|---|
| Concorrenza | `ConcurrencyLimiter`: i task annullati lasciano subito la coda; attesa limitabile (`maxWait`) | 3 test nuovi (200 waiter annullati, timeout in coda, 60 task misti), TSan pulito |
| Addon | L'attesa del permesso conta nella scadenza (max 2× timeout in coda + timeout di rete) | test limiter + suite addon |
| Cache risposte | Budget 48 MiB in memoria, 256 MiB su disco (LRU per data), file fermi da 30 giorni rimossi, file corrotti eliminati | 3 test nuovi + test esistenti di persistenza/stale |
| HTTPClient | `cancelled`/`failure` letti sotto lock (data race statica) | TSan su 1063 test: 0 avvisi |
| Sicurezza DNS | Nome non risolvibile rifiutato quando la rete locale è vietata (1 nuovo tentativo); invariato con rete locale permessa | 2 test (fail-closed, retry) |
| LiveRemux | `start()` chiude il motore su ogni uscita non riuscita, annullamento compreso (prima lo garantiva solo il chiamante) | compilazione CI |
| Immagini | File in cache corrotto riscaricato subito (una volta); decodifica fuori dall'actor, max 3 in parallelo | compilazione CI |
| Relay HLS (cast) | Test che dimostrano che le rendition `EXT-X-MEDIA` audio/sottotitoli/CC passano intatte, solo gli URI cambiano; MIME per m4a/ac3/ec3/webvtt/ttml | 5 test app |
| UX | Ricerca nelle Impostazioni; hero più basso solo su schermi bassi (SE/mini/orizzontale); carosello fermo con VoiceOver; il cast spiega perché le altre tracce audio non ci sono | 3 test app + CI |
| Concorrenza stretta | Avvisi Core in modalità `complete`: 6 → 1 | build Linux |
| CI | Gli screenshot dei branch diversi da `aether-swift-features` restano un artifact e non sovrascrivono `ci-screenshots` | — |

## Rifiutato o rimandato, con motivo
- **Unificare la navigazione Classica/Vetrina, hero più piccolo ovunque, impostazioni «Essenziale»**: contraddicono scelte
  esplicite del proprietario (layout Vetrina, hero a tutto schermo, impostazioni complete). Proposte in REDESIGN_PROPOSAL, non applicate.
- **Doppi sottotitoli, calendario, pannello tecnico**: proposti dal pacchetto esterno, ma esistono già.
- **Refactor dei file grandi (DetailView 73 KB, PlayerView 64 KB)**: nessun beneficio misurabile senza Instruments; rischio alto.
- **Swift 6 / strict concurrency nell'app**: richiede una build macOS con gli avvisi completi; piano in OPTIMIZATION_RESEARCH.

## Non verificabile da qui
Instruments, tempi di avvio, RAM/CPU/batteria reali, prove su iPhone e su televisori veri. Le procedure sono in
TEST_AND_PROFILING_PLAN e PERFORMANCE_BASELINE.
