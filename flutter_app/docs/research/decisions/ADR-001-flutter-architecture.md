# ADR-001 — Architettura Flutter

**Stato:** accettata · **Data:** 2026-10-28

**Contesto.** Servono iOS e Android con una sola base di codice, funzioni reali (addon, libreria, player, TorBox) e testabilità senza dispositivo.

**Decisione.**
- Livelli: `core/` (modelli, protocolli, regole: Dart puro, senza Flutter) → `data/` (persistenza: settings, libreria, backup, archivi) → `app/` (servizi, provider, router) → `features/` (schermate) → `design/` (token, vetro).
- Stato e dipendenze: **Riverpod 3** (`Notifier`, `FutureProvider.family`, `StreamProvider`) con `servicesProvider` sovrascritto all'avvio (nei test si sovrascrive con servizi in memoria). Motivazione: nessun contesto globale, provider annullabili con `ref.onDispose` (annullano le richieste HTTP), test semplici.
- Routing: **go_router** (shell a 5 sezioni con `StatefulShellRoute`, pagine titolo/player/impostazioni, `extra` per passare l'anteprima).
- Rete: **Dio** con timeout, `CancelToken`, limite di dimensione e adapter sostituibile nei test.
- Persistenza: `KeyValueStore` (SharedPreferences, JSON versionato, lettura tollerante) + `SecretStore` (flutter_secure_storage) dietro interfacce; libreria, impostazioni, addon, download.
- Player: interfaccia `PlaybackEngine` + `PlayerSession` (regole: ripresa, progresso, tracce preferite, sottotitoli esterni, errori) — vedi ADR-002.
- Lettura JSON esterna **sempre tollerante** (`core/util/lenient.dart`): un campo malformato non fa crollare nulla.

**Alternative scartate.** Bloc (più cerimonia per lo stesso risultato), GetX (accoppiamento globale), Drift/SQLite (non necessario ora: dati piccoli; da rivedere se la libreria cresce), file monolitici (la versione precedente concentrava tutto in pochi file).

**Conseguenze.** Tutta la logica importante è testabile in Dart puro (70+ test); le schermate sono sottili. Il costo: più file e interfacce.
