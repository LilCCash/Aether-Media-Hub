# Analisi dei concorrenti

Fatti generali noti sui prodotti, più una verifica web del 13/11/2026 (sezione «Verificato online»). Le versioni citate
solo dal pacchetto esterno (Stremio «update 86», Nuvio 0.6.11) restano non verificate.

| Prodotto | Punto di forza | Debolezza tipica | Cosa ne prende Aether |
|---|---|---|---|
| Stremio | Ecosistema addon, catalogo unificato | Player iOS limitato, UX di configurazione | Stesso protocollo addon; Aether aggiunge player doppio e cast con tracce |
| Nuvio | Addon + profili, modalità essenziale/avanzata | Funzioni avanzate nascoste | Ricerca nelle impostazioni invece di nascondere opzioni |
| Infuse | Player e libreria Apple maturi, metadati puliti | A pagamento, niente addon | Gerarchia della scheda titolo, affidabilità del cambio tracce |
| Plex / Emby / Jellyfin (Swiftfin) | Server, transcodifica lato server, sync | Richiedono un server | Aether converte sul telefono (remux) senza server |
| VLC | Formati e protocolli universali | Interfaccia spartana | Diagnostica dei formati (pannello tecnico già presente) |
| Kodi | Personalizzazione estrema | Complessità | Preset coerenti al posto di opzioni sparse |
| Apple TV app | Continua a guardare, Prossimo | Solo cataloghi Apple | «Dove eravamo rimasti?» e Prossimo episodio già presenti |

## Matrice funzionale
| Funzione | Aether | Stremio | Infuse | Jellyfin |
|---|---|---|---|---|
| Addon Stremio | sì | sì | no | no |
| Doppio motore (AVPlayer + MPV) | sì | no | proprio | proprio |
| Doppi sottotitoli | sì | no | no | no |
| Cast con cambio tracce | Google Cast sì, DLNA con ripartenza | parziale | sì | sì |
| Download offline | sì | sì | sì | sì |
| Universe / mappe narrative | sì | no | no | no |
| Trakt | sì | sì | sì | plugin |

## Conclusione
Il vantaggio di Aether non è aggiungere altre funzioni ma rendere prevedibili quelle che ha: cast, tracce e
compatibilità spiegate all'utente, impostazioni trovabili.

## Verificato online (13/11/2026)
| Prodotto | Fatto | Fonte | Implicazione per Aether |
|---|---|---|---|
| Infuse 8.5 (30/07/2026) | Gli utenti non potevano cambiare traccia audio durante la transcodifica; la 8.5.4 (14/09/2026) aggiunge il cambio audio/sottotitoli in transcodifica e corregge i sottotitoli Jellyfin | community.firecore.com (8.5 «Smarter Streaming», 8.5.4, elenchi «Upcoming Features») | Anche il riferimento del settore ha avuto lo stesso problema risolto da Aether con il cast: tracce live su Google Cast, ripartenza dal punto per MKV/DLNA |
| Infuse 8.5.6 | Sottotitoli in Picture-in-Picture in arrivo | elenchi «Upcoming Features» Firecore | Da valutare per Aether (PiP oggi solo AVPlayer) |
| Stremio 2.1 (ottobre 2026) | Calendario e anteprime in Scopri su Apple; iOS 15+ minimo | alternativeto.net (news 2026/10) | Aether ha già calendario e anteprime; nessun gap |
| Stremio (settembre 2026) | Guida TV live, zoom interfaccia, player migliorato | alternativeto.net (news 2026/9) | Aether ha guida XMLTV; lo zoom interfaccia è coperto da Dynamic Type (ora anche nelle schede Universe) |
| Stremio iOS (Reddit) | Segnalazioni aneddotiche di sottotitoli esterni assenti nel player iOS di sistema | r/Stremio | Aether invia i sottotitoli addon anche al televisore e li disegna in proprio nel player |
| Nuvio | Usa gli addon Stremio (manifest.json); su iOS non è sull'App Store, solo build della comunità (SideStore/AltStore) | docs.elfhosted.com/nuvio | Stesso canale di distribuzione di Aether; la «modalità essenziale» citata dal pacchetto esterno non è confermata dalle fonti trovate, Aether la offre comunque (spenta di default) |

Nota: le discussioni degli utenti trovate sono poche e senza data affidabile: vanno lette come indizi, non come prove.

Fonti: https://community.firecore.com/t/infuse-8-5-smarter-streaming/60410 · https://community.firecore.com/t/infuse-8-5-4-now-available/60762 ·
https://community.firecore.com/t/upcoming-features-updated-10-2-26/12345 · https://alternativeto.net/news/2026/10/stremio-2-1-brings-calendar-and-discover-previews-to-apple/ ·
https://alternativeto.net/news/2026/9/stremio-brings-live-tv-guide-interface-zoom-enhanced-video-player-and-windows-vlc-option/ ·
https://docs.elfhosted.com/nuvio/nuvio-vs-stremio/
