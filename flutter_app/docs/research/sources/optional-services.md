# Servizi opzionali: Real-Debrid, MDBList, fanart.tv, IntroDB, DLNA/UPnP

**Fonti** (2026-10-29). Il lavoro di parità con l'app iOS è partito dal **codice Swift del repository** (ramo `main-secondary`, `Packages/AetherCore/Sources/AetherCore/…`), che documenta il comportamento già verificato lì. **Non** è stata riletta la documentazione ufficiale dei servizi in questa sessione (host non raggiungibili dall'ambiente, vedi README): quanto segue è quindi «come lo usa l'app iOS», non «come lo dichiara il fornitore».

| Servizio | Come lo usa Aether | Origine del contratto | Stato |
|---|---|---|---|
| Real-Debrid `https://api.real-debrid.com/rest/1.0` | `Authorization: Bearer <token>`, corpi form-urlencoded; `GET /torrents` (riuso se già presente), `POST /torrents/addMagnet`, `POST /torrents/selectFiles/{id}` (`files=all`), `GET /torrents/info/{id}` finché `status=downloaded`, `POST /unrestrict/link` → `download` (solo https). Nessuna sonda di cache: `instantAvailability` è ritirato (errore 37, come annotato nel client Swift). | `Debrid/RealDebridClient.swift` | server finto |
| MDBList `https://api.mdblist.com` | `GET /tmdb/{movie|show}/{id}?apikey=…` → `ratings[]` (`source`, `value`, `score`, `votes`); `GET /user` per verificare la chiave. | `Metadata/MDBListClient.swift` | server finto |
| fanart.tv `https://webservice.fanart.tv/v3` | `GET /movies/{imdb|tmdb}` e `/tv/{tvdb}?api_key=…`; sceglie il logo (`hdmovielogo`, `hdtvlogo`, `movielogo`, `clearlogo`) nella lingua dell'utente, poi inglese, poi il più apprezzato; accetta solo immagini https di `fanart.tv`. | `Metadata/FanartClient.swift` | server finto |
| IntroDB `https://api.introdb.app` | `GET /segments?imdb_id=tt…&season=N&episode=M` → `intro`, `recap` (`start_sec`/`end_sec` o `*_ms`); durata accettata 3–600 s; 404 = nessun dato. Dati di volontari: possono slittare di qualche secondo con un'altra versione dell'episodio. Nessuna chiave. | `Segments/SkipSegments.swift` | server finto |
| DLNA/UPnP AV | SSDP `M-SEARCH` (multicast 239.255.255.250:1900) → `LOCATION` → descrizione XML → `controlURL` di AVTransport/RenderingControl → SOAP `SetAVTransportURI` (con DIDL-Lite), `Play`, `Pause`, `Stop`, `Seek`, `GetTransportInfo`, `SetVolume`. Si invia il **link**: la TV lo scarica. | `Casting/UPnP.swift` (+ specifiche UPnP AV) | server finto; **nessuna TV reale** |

**Scelte di sicurezza aggiunte in Flutter.** DLNA: risposte SSDP e indirizzi di controllo accettati solo se sulla rete locale e sullo stesso host che ha risposto (un estraneo sulla rete non può puntare l'app verso un server qualsiasi); i link trasmessi non compaiono nei messaggi di errore. Tutte le chiavi: archivio sicuro, lette a ogni chiamata, mai nei log (`AppLog.redact` copre `apikey`, `api_key`, `token`, `Bearer`).

**Limite di piattaforma (DLNA).** Su iOS l'invio di pacchetti multicast richiede l'entitlement di Apple «Multicast Networking», che si ottiene su richiesta e non è disponibile per un'app installata fuori dallo store: la ricerca delle TV è quindi abilitata solo su Android (`UpnpDiscovery.supported`). Fonte: conoscenza della piattaforma, **non riletta oggi**.

**Non verificato.** Nessuna chiamata reale ai servizi sopra; nessuna TV; nessun telefono.
