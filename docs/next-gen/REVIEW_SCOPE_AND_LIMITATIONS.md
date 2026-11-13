# Ambito e limiti

- **Letto riga per riga:** i file toccati dai fix e i loro chiamanti (limiter, AddonService, HTTPClient, NetworkPolicy,
  ResponseCache, LiveRemux + LocalRemuxService, ImageLoader, AdaptiveStreamRelaySource, CastTrackControls, Home hero,
  radice delle Impostazioni). Il resto dei 407 file è stato censito per modulo, non certificato riga per riga.
- **Eseguito:** suite Core completa su Linux (anche con TSan e ASan), conteggio avvisi Swift 6 del Core, CI macOS
  (build app, unit test, UI test mirati, screenshot) e Build IPA sul branch.
- **Non eseguito:** Instruments, misure su dispositivo, prove con televisori veri, Thread Sanitizer sull'app iOS
  (richiede uno schema Xcode dedicato).
- **Non modificato:** `aether-swift-features`, `main`, `ci-screenshots`, branch Android TV.
- **Scelte di prodotto del proprietario** (layout Vetrina, hero a tutto schermo, impostazioni complete) non sono state cambiate.
