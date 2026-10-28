# Flutter: interfaccia adattiva e «liquid glass»

**Fonti** (consultate 2026-10-28)
- Flutter, *Adaptive and responsive design* — https://docs.flutter.dev/ui/adaptive-responsive — **non raggiungibile** dall'ambiente (proxy).
- Flutter, *BackdropFilter* — https://api.flutter.dev/flutter/widgets/BackdropFilter-class.html — **non raggiungibile**; letto lo stesso testo come commento nel sorgente
  `packages/flutter/lib/src/widgets/basic.dart` (raw.githubusercontent.com/flutter/flutter, ramo master).
- Flutter, *ImageFiltered* — https://api.flutter.dev/flutter/widgets/ImageFiltered-class.html — **non raggiungibile**; stesso sorgente (`basic.dart`).
- Versione di Flutter usata: **3.47.8** (stable, 22/10/2026, Dart 3.13.7), verificata con `flutter --version`.

**Sintesi.** `BackdropFilter` applica un filtro (per esempio `ImageFilter.blur`) a tutto ciò che è già stato dipinto *sotto* il suo rettangolo di
clip; il commento nel sorgente avverte che è un'operazione costosa e che va racchiusa in un clip (`ClipRect`/`ClipRRect`) per limitarne l'area, e mostra
`ImageFiltered` come alternativa quando il filtro serve a sfocare il *figlio* e non lo sfondo. Per un effetto vetro serve per forza il blur dello sfondo, quindi `BackdropFilter`.

**Implicazioni per Aether**
- `GlassSurface` (lib/design/glass.dart) applica il blur **solo** nel rettangolo ritagliato di ogni superficie, mai a schermo intero, e dentro un `RepaintBoundary`.
- Fallback performante: se l'utente sceglie «Riduci gli effetti», se l'intensità del vetro è ≈ 0 o se il sistema chiede di ridurre le animazioni, la superficie diventa opaca (nessun `BackdropFilter`).
- Layout adattivo: griglie con `SliverGridDelegateWithMaxCrossAxisExtent`, controlli con area minima 44 px, `SafeArea` ovunque, testo che rispetta la scala di sistema.
- Il sistema grafico (token, `AetherLook`, `GlassSurface`, `GlassButton`, `AetherBackdrop`) è in `lib/design/`.

**Limiti.** Non esiste in Flutter un equivalente dell'API nativa Liquid Glass di iOS 26: l'aspetto è una **ricostruzione** (blur + gradiente + bordo chiaro + ombra), non il materiale di sistema.
Le prestazioni su telefoni economici non sono state misurate (nessun dispositivo disponibile): vedi docs/LIMITATIONS.md.

**Verificato.** Codice del widget letto nel sorgente; comportamento dei nostri widget coperto da test (nessun overflow sulle schermate principali a 360×800).
**Non verificato.** Fluidità reale (fps) su dispositivi.
