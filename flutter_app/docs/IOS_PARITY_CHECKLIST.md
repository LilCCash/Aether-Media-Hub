# Checklist di parità con l'app iOS (ramo `main-secondary`, commit b39234c)

Ricavata leggendo il codice Swift (`App/Aether/**`, `Packages/AetherCore/**`: impostazioni, schermate, servizi). ✅ = presente in Flutter (con test dove indicato in FEATURE_PARITY/TESTING) · ⬜ = ancora da portare · 🚫 = impossibile o non sensato su Flutter/Android (motivo).
Una voce è spuntata solo quando il codice c'è **e** `flutter analyze`/`flutter test` passano; nessuna è stata provata su un telefono.

## A. Addon e cataloghi
- ✅ A1 Installazione da URL con anteprima, avvisi, duplicati, `stremio://` e `aether://`
- ✅ A2 Abilita/disabilita, rinomina, rimuovi, aggiorna, ordine/priorità degli addon
- ✅ A3 Cataloghi: nomi personalizzati, ordine, nascondi; Home e Scopri
- ✅ A4 Filtri tipo/genere/decennio in Cerca e Libreria; ricerca locale in libreria
- ✅ A5 Ricerca: ordinamento (rilevanza/altro), «cerca anche nella libreria», cronologia on/off
- ⬜ A6 Scopri: tipi configurabili e catalogo predefinito per tipo
- ✅ A7 Aggiornamento dei cataloghi ogni N minuti e cache on/off (Metadati e cataloghi)
- ✅ A8 Nascondi cataloghi per adulti; rete locale consentita

## B. Sorgenti
- ✅ B1 Analisi del nome (qualità, codec, HDR, audio, lingue, dimensione, formato)
- ✅ B2 **Ordine delle sorgenti**: per addon (ordine degli addon) / per qualità
- ✅ B3 Filtro per addon, badge a scelta (quali mostrare), stile dei badge (pieni/contorno/testo), logo dell'addon sulla riga
- ✅ B4 Badge importati da un link (formato Nuvio/Fusion)
- ✅ B5 Limite di qualità (4K/1080p/720p) e «preferisci sorgenti nella lingua audio»
- ✅ B6 «Scegli automaticamente la sorgente migliore»
- ✅ B7 **Menu a tendina (pressione lunga) sulla sorgente**: Riproduci / Scarica / Copia link
- ✅ B8 Pillola «in cache» (TorBox)

## C. Debrid e metadati
- ✅ C1 TorBox (cache, conferma prima del download, annulla attesa)
- ✅ C2 Real-Debrid, selettore del servizio
- ✅ C3 **Il player si apre subito** e mostra il logo mentre contatta TorBox/Real-Debrid
- ✅ C4 TMDB (cast, filmografia, trailer, produzione, saga, simili)
- ✅ C5 MDBList (voti), TheTVDB (episodi), fanart.tv (logo)
- ✅ C6 **Opzioni per attivare/disattivare i moduli TMDB** (cast, trailer, produzione, incassi, dettagli, simili, saga)
- ✅ C7 **Opzioni MDBList**: voti on/off, quali servizi mostrare (il «voto sulle locandine» mostra il voto IMDb dato dall'addon)
- ⬜ C8 «Metadati forniti da…» / «Offerto da TMDB» e info del provider nella scheda

## D. Scheda titolo
- ✅ D1 Hero, trama, generi, cast con foto, filmografia della persona, stagioni/episodi, visto/progressi
- ✅ D2 Watchlist, preferiti, segna visto
- ⬜ D3 Trama espandibile e trailer su YouTube ci sono (✅); manca il link IMDb dell'episodio
- ✅ D4 Indicatore «Esce il …» per episodi futuri
- ✅ D5 **Scarica l'intera stagione** (lingua, qualità rigorosa, peso, addon esclusi, prova la sorgente successiva, annulla, riepilogo). ⬜ non portato: il cambio automatico di sorgente se un download già avviato fallisce più tardi
- ✅ D6 Download di un singolo titolo/episodio (link diretti, pausa/ripresa)
- ✅ D7 Download: limite simultanei, solo Wi-Fi, elimina dopo la visione, riproduci offline. ⬜ spazio libero del dispositivo (dart:io non lo espone)

## E. Player
- ✅ E1 Orizzontale, ripresa, successivo con conto alla rovescia, sorgente alternativa, blocco, velocità, formato
- ✅ E2 Salta intro/riassunto, gesti di luminosità/volume, doppio tocco, trascinamento
- ✅ E3 **Sottotitoli addon divisi per lingua → addon** (e categoria: incorporati / addon / file)
- ✅ E4 Lingue di riserva (audio e sottotitoli), stile dei sottotitoli completo (colore, contorno, sfondo, grassetto, posizione)
- ✅ E5 Salto avanti/indietro configurabile, nascondi controlli dopo N s, riavvolgi alla ripresa, soglia «visto»
- ✅ E6 Pressione prolungata per accelerare (velocità), timer di spegnimento
- ✅ E7 Regolazioni immagine (luminosità/contrasto/saturazione/gamma), decodifica hardware, deband, tono HDR, buffer
- ✅ E8 PiP (Android), DLNA «Trasmetti sulla TV» (Android)
- 🚫 E9 AirPlay, Google Cast nativo, ponte e remux MKV→MP4, AVPlayer: legati a iOS/SDK Google
- ✅ E11 «Continua l'audio in background» e Picture-in-Picture automatico (Android: all'uscita dall'app; non provato su telefono)

## F. Navigazione
- ✅ F1 **Gesto per tornare indietro** (scorrimento dal bordo) in schede, menu e pagine, anche su Android
- ✅ F2 Foglio delle sorgenti chiudibile trascinando

## G. Impostazioni e personalizzazione
- ✅ G1 AMOLED, Dynamic Cinematic, vetro/riduci effetti, accento, palette (8), carattere dei titoli, saluto
- ✅ G2 Colore d'accento personalizzato (esadecimale/selettore) e colore di sfondo personalizzato
- ✅ G3 Stile dello sfondo (aurora / onde / faro / tinta unita) e intensità
- ✅ G4 Cornice delle schede (standard/contorno/ombra/alone) e angoli (netti/standard/morbidi/bolle)
- ✅ G5 Dimensione locandine, voto sulle locandine, aloni colorati, animazioni on/off. 🚫 «Densità» non portata
- ✅ G6 Home: sezioni visibili/ordinabili (In evidenza, Continua, Prossimi episodi, Watchlist, Cataloghi) con stile e dimensione per sezione
- ✅ G7 Hero: stile (card / schermo intero) e scorrimento automatico
- ⬜ G8 Tema chiaro/scuro/automatico → 🚫 solo scuro in Flutter (rifacimento completo dei colori)
- ✅ G9 Moduli della scheda del titolo (G/C6) e dei voti (C7)
- ✅ G10 Servizi: chiavi TorBox, Real-Debrid, TMDB, TVDB, MDBList, fanart.tv
- ✅ G11 Dati: backup su file (crea/ripristina, includi chiavi/addon), elimina tutti i dati locali, cancella cronologia/ricerche
- ✅ G12 Archiviazione: svuota cache immagini e cataloghi. ⬜ limite in MB della cache immagini e spazio libero
- ✅ G13 Diagnostica: log on/off, esporta log
- ✅ G14 Due easter egg nella pagina Informazioni (logo dell'app e logo di Theater Mode), come su iOS

## H. Theater Mode
- ✅ H1 Rail, hero, righe, palette, sfondi, dimensioni, locandine verticali, fori pellicola, introduzione e suono, pagina «Altro»
- ✅ H2 Angoli/bordo/alone, stile titoli di riga. ⬜ effetto proiettore
- ⬜ H3 Foglio sorgenti a due colonne in Theater
