# Aether Android TV — prestazioni

Priorità n. 1 del progetto. Qui ci sono le scelte fatte e i numeri **misurati davvero**; quello che richiede una TV fisica è
segnato come tale, senza cifre inventate.

## Misurato (build dell'11–12/11/2026, macchina di build Linux, JDK 21)
| Voce | Valore |
|---|---|
| APK release (R8 minify + shrink risorse, firmato) | **3,4 MB** (3 579 132 byte); `classes.dex` 5,2 MB non compresso |
| APK debug | 26,5 MB (senza R8, solo per sviluppo) |
| Profilo di avvio nell'APK | `assets/dexopt/baseline.prof` presente (profili delle librerie AndroidX via ProfileInstaller) |
| Test del nucleo (105 test, 19 classi) | 14 s compilazione compresa, `--rerun-tasks` |
| Build release locale a freddo | ~3 min 20 s (R8 incluso) |

## Scelte che pesano sulle prestazioni
- **Avvio**: nessuna libreria di DI, motore (`AetherEngine`) costruito pigramente al primo uso; i file JSON letti solo quando servono.
  Le capacità della TV (decoder, HDR) si leggono una volta e restano in memoria.
- **Liste**: solo `LazyRow`/`LazyColumn`/`LazyVerticalGrid` con chiavi stabili e senza duplicati; la posizione del focus di ogni riga
  è ricordata (`FocusMemory`) per non ricomporre tutto al ritorno.
- **Immagini**: Coil 3 con cache in memoria al 15% della RAM, cache su disco 200 MB, `RGB_565` permesso, dissolvenza breve; le card
  chiedono l'immagine alla loro misura.
- **Rete**: un solo client OkHttp; richieste agli addon in parallelo ma limitate (semaforo), con timeout e annullamento strutturato
  (uscire da una schermata annulla le richieste in corso); cache delle risposte; la guida XMLTV si legge in streaming (SAX + gzip)
  tenendo solo una finestra di 39 ore; le playlist M3U fino a 20 000 canali vengono analizzate fuori dal thread principale.
- **Scaffali Trakt**: una sola chiamata TMDB leggera per titolo, al massimo 6 in parallelo, con cache.
- **Player**: Media3 ExoPlayer con decodifica hardware; il punteggio delle sorgenti penalizza codec che la TV non decodifica e HDR che
  lo schermo non mostra, così la sorgente consigliata parte davvero.
- **Download**: lavoro in primo piano di WorkManager, buffer da 256 KB, scrittura con `RandomAccessFile`, aggiornamento dello stato
  al massimo una volta al secondo.
- **Sfondo**: animazioni disattivabili (Impostazioni ▸ Aspetto) per i box più lenti.

## Da misurare su una TV (non fatto in questo lavoro)
Avvio a freddo e a caldo (`am start -W`), fotogrammi saltati scorrendo la Home (`dumpsys gfxinfo`), memoria con molte righe aperte,
tempo al primo fotogramma del player. Non avendo un dispositivo Android TV né un emulatore con accelerazione nella macchina di build,
questi numeri non sono stati raccolti: vanno presi sul primo hardware disponibile. Un Baseline Profile generato dall'app stessa
(Macrobenchmark) è il passo successivo consigliato.
