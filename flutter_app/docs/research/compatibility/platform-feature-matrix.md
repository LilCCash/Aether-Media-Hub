# Funzioni per piattaforma (2026-10-28)

| Funzione | iOS (Flutter) | Android (Flutter) | Note |
|---|---|---|---|
| Addon, cataloghi, ricerca, libreria | implementato (CI) | implementato (CI) | non provato su telefono |
| Player (mpv) | compilato | compilato | non eseguito su telefono |
| Orientamento orizzontale del player | `SystemChrome` | `SystemChrome` | da provare |
| PiP | **assente** (libmpv) | implementato a livello di attività | da provare |
| AirPlay | **assente** | — | richiede AVPlayer |
| Google Cast | — | **assente** | richiede Cast SDK |
| Archivio sicuro | Keychain | EncryptedSharedPreferences/Keystore | `flutter_secure_storage` |
| Download offline | implementato (link diretti) | implementato | Torrent: no |
| Deep link `stremio://` | assente | assente | parser pronto |
| Android TV / telecomando | — | non verificato | non obiettivo |
| Theater Mode | **non portato** | — | vedi FEATURE_PARITY |
