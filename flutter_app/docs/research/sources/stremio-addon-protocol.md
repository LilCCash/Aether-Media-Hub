# Protocollo degli addon Stremio

**Fonti** (consultate 2026-10-28)
- Protocollo — https://stremio.github.io/stremio-addon-sdk/protocol.html — sito non raggiungibile; letto il file sorgente
  https://raw.githubusercontent.com/Stremio/stremio-addon-sdk/master/docs/protocol.md (200).
- Manifest — https://github.com/Stremio/stremio-addons/blob/master/docs/api/manifest.md (403 su github.com); letto
  https://raw.githubusercontent.com/Stremio/stremio-addons/master/docs/api/manifest.md e `…/stremio-addon-sdk/master/docs/api/responses/manifest.md` (200).
- Risposte `stream`, `meta` e richiesta `catalog` — `stremio-addon-sdk/master/docs/api/responses/{stream,meta}.md` e `requests/defineCatalogHandler.md` (200).
- https://docs.stremio-addons.net/developers/api — non raggiungibile.

**Sintesi (dai testi letti).**
- Un addon è un server HTTP con `/manifest.json` e risorse `/{resource}/{type}/{id}.json`: `catalog`, `meta`, `stream`, `subtitles` (più `addon_catalog`, `player`, `library`).
- Argomenti extra: `/{resource}/{type}/{id}/{extraArgs}.json` con `extraArgs` in forma di query string (es. `search=game%20of%20thrones&skip=100`).
- Ogni route, compreso il manifest, deve servire intestazioni CORS che consentono ogni origine.
- Il manifest dichiara `resources` (stringhe o oggetti con `name`, `types`, `idPrefixes`), `types`, `idPrefixes`, `catalogs` (con `extra` e, nei manifest vecchi, `extraSupported`/`extraRequired`), `behaviorHints` (`configurable`, `configurationRequired`, `adult`, `p2p`).
- La risposta `stream` ha `url` | `infoHash` (+`fileIdx`) | `ytId` | `externalUrl`, `name`, `description`/`title`, `behaviorHints` (`bingeGroup`, `videoSize`, `filename`, `notWebReady`, `proxyHeaders`), `subtitles`, `sources` (tracker).
- Nel testo del protocollo l'`id` di `subtitles` è l'hash OpenSubtitles con `videoID`/`videoSize` in `extraArgs`; molti addon accettano anche l'ID del video. **Da verificare con un addon reale.**

**Implementazione** (lib/core): `AddonManifest`/`MetaItem`/`AddonStream` con lettura tollerante, `AddonClient` (timeout 10/20 s, annullabile con `CancelToken`, risposta ≤ 6 MB, cache `cacheMaxAge`),
`NetworkPolicy` (solo http/https, niente `user:pass@`, `localhost`/127.x sempre vietati, rete locale solo se abilitata), `AddonRepository` (anteprima → conferma → installazione; indirizzo in archivio sicuro).
Nessun codice dell'addon viene eseguito: solo JSON.

**Verificato.** Parsing, URL, errori, cache, priorità: 25+ test automatici (`test/core_model_test.dart`, `addon_client_test.dart`). **Non verificato** contro addon reali in rete (nessun accesso a internet aperto dall'ambiente di test).
