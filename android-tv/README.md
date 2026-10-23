# Aether per Android TV

La versione per televisori Android TV / Google TV di Aether: un media center in italiano che mostra e riproduce i contenuti dei **tuoi addon Stremio**. È indipendente dall'app per iPhone (cartelle `App/`, `Packages/`, `Config/`): le due app condividono il repository e le funzioni, ma non il codice.

> Aether non fornisce nessun contenuto: cataloghi e sorgenti arrivano dagli addon che installi tu.

## Cosa c'è qui

```
android-tv/
├── core/        libreria Kotlin pura (JVM): protocollo addon, manifest, ricerca, ordine delle sorgenti,
│                libreria/cronologia/backup, TorBox, IntroDB. Si compila e si prova anche senza Android SDK.
├── app/         l'app Android TV (Kotlin + Jetpack Compose + Media3/ExoPlayer)
├── docs/PARITA.md   matrice di parità con la versione per iPhone, con lo stato vero di ogni funzione
└── gradle/, gradlew, settings.gradle.kts
```

- **Schermate**: Home (titolo in evidenza, «Continua a guardare», «Prossimo episodio», cataloghi), Scopri, Cerca, Dettagli (stagioni, episodi), scelta della sorgente, Player, Libreria, Addon, Impostazioni, Informazioni.
- **Telecomando**: tutto si usa con D-pad, OK, Indietro e Play/Pausa. L'elemento selezionato si ingrandisce e prende un bordo del colore d'accento; tornando indietro il focus rimane sul poster dove eri.
- **Nel player**: OK = pausa; Sinistra/Destra = salto (più si tiene premuto, più è lungo) e la barra resta in vista finché continui a premere; Su/Giù = controlli; Indietro chiude pannello → controlli → player.

## Compilare

Serve JDK 17. Per l'app serve anche l'Android SDK (la CI lo ha già).

```bash
cd android-tv
./gradlew :core:test -PcoreOnly=true        # solo il core: nessun Android SDK necessario
./gradlew :app:assembleDebug                # l'APK di prova: app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:lintDebug :app:testDebugUnitTest
```

### Installare sulla TV

Abilita le opzioni sviluppatore e il debug USB/di rete sulla TV, poi:

```bash
adb connect <indirizzo-della-TV>:5555
adb install -r app-debug.apk
```

L'app compare nel launcher di Android TV / Google TV con il suo banner. Per aprire un addon da un link: `adb shell am start -a android.intent.action.VIEW -d "stremio://host/percorso/manifest.json"` (l'app chiede conferma prima di installarlo).

## CI e APK

Il workflow `.github/workflows/android-tv.yml` parte solo quando cambia `android-tv/` (o il workflow stesso), gira su Linux e non tocca la pipeline iOS:

1. **Core**: test del modulo Kotlin;
2. **App**: build, lint, test unitari, controllo del pacchetto (nome, `leanback`, touchscreen non richiesto, banner), controllo che non ci siano file iOS dentro `android-tv/`, **APK di prova come artifact** (Actions → l'esecuzione → *Artifacts* → `Aether-AndroidTV-debug-apk`).

L'APK di prova è firmato con la chiave di debug. Per un APK di release firmato, nei *Secrets* del repository (Settings → Secrets and variables → Actions) metti `ANDROID_KEYSTORE_BASE64` (il `.jks` in base64), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, e avvia il workflow a mano con «release». Nessuna chiave o password sta nel repository.

## Cosa non è stato provato

Vedi `docs/PARITA.md`. In breve: il core ha test automatici; l'interfaccia e il player **compilano in CI ma non sono stati provati su una TV o su un emulatore** (nessuno dei due era disponibile). Navigazione con il telecomando, aspetto, fluidità, decodifica dei video sulla TV vera e TorBox contro il servizio reale sono da verificare su un dispositivo.
