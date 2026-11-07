# Aether Pro — stato rispetto alla visione (branch `aether-pro`)

Fatto vero = scritto e con test nel Core dove possibile. **Nulla è provato su un iPhone.** ✅ nel codice · 🟡 parziale · ☐ non fatto.

| Area della visione | Stato | Note |
|---|---|---|
| Universe (14 universi, ordini, progresso, segui, ordine personale) | ✅ | Dati in `Universe/Universe.swift`, ogni ID confrontato con Cinemeta (nome e anno). L'ordine della storia è **editoriale**, non ufficiale; per gli universi senza ordine diverso vale l'uscita. Nessun grafo di relazioni tra personaggi. |
| People (bio, ruoli, filmografia filtrabile, ricerca) | ✅ | TMDB. Premi e collaborazioni non fatti. |
| Diario, voti, note, rewatch, statistiche | ✅ | Nelle impostazioni (quindi nei backup). |
| Libreria: visti, abbandonati, collezioni | ✅ | «Abbandonati» = non finiti e fermi da 30 giorni. |
| Home con sezione Universe, personalizzabile | ✅ | Le altre sezioni c'erano già. |
| Ricerca di universi e persone | ✅ | Episodi e franchise non indicizzati. |
| Source Intelligence con criteri | 🟡 | Pesi configurabili; HDR e audio **dal nome** della release (etichette, non misure). Nessuna misura del file prima di avviarlo. |
| Provider TorBox e Real-Debrid | ✅ (già presenti) | Client in `Debrid/`. |
| Player AVPlayer + MPV, skip intro, pausa, sottotitoli | ✅ (già presenti) | PiP con MPV non fatto. |
| Download, widget, Live Activity, SharePlay, notifiche | ✅ (già presenti) | Limiti iOS e della firma gratuita. |
| Navigazione | ✅ | Dock invariata (Home, Scopri, Libreria, Cerca, Altro). Universe e Live TV: pulsanti in alto nella Home e voci in Altro. |
| Design: logo, hero della scheda, pulsante bianco, dock traslucida, controlli del player a riquadri, intestazioni di sezione | 🟡 | Rifatti a codice, mai visti su schermo: va guardato e rifinito sul telefono. Liquid Glass solo dove c'era già. |
| Scheda episodio con trama in long-press | 🟡 | Tocco lungo sulla riga apre il foglio dell'episodio che già c'era. |
| Sincronizzazione tra dispositivi | 🟡 | Un file in una cartella scelta (iCloud Drive o altro): unione di libreria, cronologia, diario, collezioni, voti. Non è CloudKit (serve account sviluppatore) né un server. Mai provata con due dispositivi. |
| Movie Companion | 🟡 | Solo fatti dai metadati e dagli universi, con 3 livelli di spoiler; nessuna curiosità inventata. |
| Modalità Cinema | 🟡 | Scheda prima del film e controlli minimi; il valore su iPhone è da giudicare a occhio. |
| AI (assistente, ricerca semantica) | ☐ | Esiste la ricerca avanzata con motore AI opzionale. |
| Handoff | 🟡 | Dalla scheda titolo. Spotlight e scorciatoie già presenti. |
| Raccomandazioni | 🟡 | «Scelti per te» dai generi e dai voti, senza algoritmi complessi. |
| Real-Debrid / AI nel backup | ☐ | Le loro chiavi non sono nel backup (svista segnalata). |
