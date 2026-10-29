# Versione Android

Questo ramo (`aether-flutter-android`) contiene l'app Flutter **per Android**: stesso codice Dart dell'altra versione, ma con la parte nativa
Android (cartella `android/`, player libmpv, Picture in Picture e Google Cast per Android). La conversione MKV → HLS e il player di sistema
sono solo iPhone: qui non servono (libmpv e Android aprono gli MKV così come sono).
La versione iPhone è nel ramo `aether-flutter-ios`. Il workflow `Flutter Build · Android APK` compila questo ramo.
