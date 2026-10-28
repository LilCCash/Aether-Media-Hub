# ADR-003 — Integrazione nativa

**Stato:** accettata · **Data:** 2026-10-28

**Decisione.** Il codice nativo è ridotto al minimo e isolato: oggi solo `MainActivity.kt` (canale `app.aether/pip`). Orientamento, schermo acceso e archivio sicuro usano plugin. Nessun `MethodChannel` per funzioni che un plugin già copre.

**Orientamento del player.** `SystemChrome.setPreferredOrientations(landscape)` all'ingresso, `portraitUp` all'uscita; modalità immersiva. Nel player SwiftUI di Aether iOS questo richiese un contenitore UIKit dedicato; in Flutter c'è un solo `FlutterViewController`, quindi non si ripresenta lo stesso problema (**da confermare su iPhone**).

**Da fare quando ci sono dispositivi.** Adapter AVPlayer/AVKit per PiP e AirPlay su iOS; Cast SDK su Android; deep link `stremio://`/`aether://` (il parser esiste, mancano le dichiarazioni nativi e il gestore).
