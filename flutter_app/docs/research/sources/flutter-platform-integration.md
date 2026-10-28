# Flutter: integrazione di piattaforma (platform channels)

**Fonte.** Flutter, *Writing custom platform-specific code* — https://docs.flutter.dev/platform-integration/platform-channels — **non raggiungibile** dall'ambiente il 2026-10-28.
Alternativa: il meccanismo è usato e documentato nei sorgenti dei plugin letti (media_kit, wakelock_plus) e nella documentazione Android del PiP (vedi scheda Android).

**Cosa si sa e si usa** (conoscenza del framework, confermata dal funzionamento del codice compilato in CI):
- Un `MethodChannel` collega Dart e il codice nativo con messaggi asincroni; il lato nativo si registra in `configureFlutterEngine`.
- In Aether il canale `app.aether/pip` (Android, Kotlin, `MainActivity`) espone `enter` (chiama `enterPictureInPictureMode`) e invia `pipChanged` quando la finestra diventa flottante.

**Implicazioni.** Le integrazioni native sono tenute minime e isolate (ADR-003): oggi solo il PiP Android. Orientamento, schermo sempre acceso (`wakelock_plus`) e portachiavi (`flutter_secure_storage`) passano da plugin.

**Verificato.** Compilazione del codice Kotlin: da verificare nella build Android (CI). **Non verificato** su dispositivo: l'effettivo ingresso in PiP.
