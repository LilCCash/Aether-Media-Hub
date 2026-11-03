# Aether Web

Versione web semplificata di Aether: **addon, cataloghi, riproduzione nel browser e lettori esterni**. Solo italiano, accesso con password.

## Cosa fa
- Installa addon Stremio dal link del manifest; Home, «Scopri» (con generi), ricerca, scheda del titolo, stagioni ed episodi.
- Elenca le fonti degli addon con qualità, dimensione e un'indicazione onesta di cosa farà il browser.
- Riproduce MP4/WebM e flussi HLS (`hls.js`), con ripresa da dove eri e sottotitoli degli addon.
- Apre il video in **VLC, Infuse, nPlayer, Outplayer, VLC/MX Player per Android**, oppure copia il link o scarica una playlist `.m3u`.
- Preferiti e cronologia nel browser. Si installa come app dalla schermata Home (PWA).

## Cosa non fa
MKV, AVI, DTS e molti HEVC non si riproducono nel browser: per quelli c'è il lettore esterno. I torrent non partono (serve un addon con TorBox o Real-Debrid, che dà un link diretto). Un addon che non permette l'accesso dal browser (CORS) non funziona. Nessuna ricerca con AI, nessun download.

## La password
È un **lucchetto educato, non una cassaforte**: il sito è statico e i suoi file sono pubblici (GitHub Pages). Nella pagina non c'è nessun segreto: addon e dati stanno nel browser di ciascuno. La password è controllata con PBKDF2 (210.000 giri) contro un valore salato in `src/auth-config.json`. Per cambiarla:

```
cd web
node scripts/set-password.mjs "nuova password"
git commit -am "Nuova password" && git push
```

## Sviluppo
```
cd web
npm ci
npm test            # logica (addon, fonti, lettori esterni, password)
npm run build       # controllo dei tipi + sito in dist/
node scripts/smoke.mjs "<password>"   # prova completa in un browser vero contro un addon finto (serve Playwright)
```

## Pubblicazione
Il flusso `.github/workflows/web-pages.yml` costruisce e pubblica su GitHub Pages a ogni modifica di `web/` sul ramo `aether-web`. Una volta sola: Impostazioni ▸ Pages ▸ Source = «GitHub Actions».

_Ultimo aggiornamento della pubblicazione: 3 novembre 2026._

Pubblicazione: https://lilccash.github.io/Aether-Media-Hub/
