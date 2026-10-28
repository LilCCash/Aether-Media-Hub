# Build e rilascio (2026-10-28)

Toolchain: Flutter **3.47.8** stable (Dart 3.13.7). Cartella del progetto: `flutter_app/`.

## Locale
```
cd flutter_app
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-fatal-infos
flutter test
flutter build apk --release --split-per-abi      # APK
flutter build ios --release --no-codesign        # solo su macOS
```
I video di prova si rigenerano con `sh tool/make_test_media.sh` (serve ffmpeg).

## GitHub Actions (ramo `aether-flutter-comp`)
- **Flutter CI** (`.github/workflows/flutter-ci.yml`): a ogni push che tocca `flutter_app/` — formattazione, analisi, test.
- **Flutter Build (APK + IPA)** (`.github/workflows/flutter-build.yml`): parte in un push solo se il messaggio del commit contiene **`[build]`**, oppure a mano (*Run workflow*, ma i workflow appaiono nell'elenco solo se presenti sul ramo predefinito).
  Produce gli artefatti `aether-flutter-apk` (APK per ABI + universale) e `aether-flutter-ipa-unsigned` (`Aether-flutter-unsigned.ipa`), scaricabili dalla pagina dell'esecuzione.

## Prerequisiti e blocchi
- **IPA:** non firmato (nessun certificato nel repository). Va firmato con AltStore/Sideloadly o con un proprio certificato e provisioning profile.
- **APK:** firmato con la chiave di debug di Flutter: installabile per prove, non per uno store. Per la distribuzione serve una propria keystore (da configurare come segreto, mai nel repository).
- Nessuna pubblicazione su store è stata fatta né è prevista senza autorizzazione.
