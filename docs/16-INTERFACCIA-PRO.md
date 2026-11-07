# Interfaccia Pro — stato rispetto alla visione

L'app ora è una sola («Aether»): l'interfaccia Pro è un interruttore in Impostazioni ▸ Aspetto. Le funzioni nuove valgono in entrambe le interfacce.
**Nulla è provato su un iPhone.** ✅ nel codice con test dove possibile · 🟡 sperimentale o parziale · ☐ non fatto.

| Area | Stato | Note |
|---|---|---|
| Interruttore Classica / Pro | ✅ | `AppearanceSettings.switchInterface`: ricorda l'aspetto della Classica e lo ripristina (test). Struttura: barra, Home, pagina titolo. |
| Barra di sistema (Pro: 4 voci + ricerca separata) | 🟡 | Usa il ruolo «search» di `Tab` (iOS 18; la separazione in Liquid Glass la disegna iOS 26). Prima di iOS 18 resta la barra a 5 voci. |
| Universe (14 universi, ordini, progresso, attori che tornano, collegamenti) | ✅ | ID confrontati con Cinemeta. Ordine della storia **editoriale**. Collegamenti solo se fatti certi (Alien↔Predator). |
| Persone (bolla, ruoli, biografia, premi, collaborazioni, ricerca) | ✅ | TMDB (chiave tua) e Wikidata per i premi. |
| Diario, timeline, statistiche | ✅ | Nelle impostazioni (quindi nei backup). |
| Libreria: visti, abbandonati, collezioni; «Scelti per te» | ✅ | |
| Intelligenza delle fonti | 🟡 | Pesi configurabili; HDR e audio dal nome della release (etichette, non misure). |
| Companion + domande all'AI | 🟡 | Fatti da metadati e universi; l'AI usa la tua chiave. |
| Modalità Cinema | 🟡 | Scheda prima del film e controlli minimi. |
| Anteprime sulla barra di avanzamento | 🟡 | FFmpeg (già nell'app) legge il fotogramma chiave dal file ORIGINALE: vale per MKV, AVI, TS, WebM, HLS e MP4, con AVPlayer e con MPV. Mai provato su dispositivo; l'HDR può apparire spento e un 4K ad alto bitrate può tardare. Se FFmpeg non riesce, AVFoundation (solo AVPlayer e file semplici). |
| Opzioni del player (foglio) | ✅ | Sostituisce il menu che sfarfallava. |
| PiP con MPV | 🟡 | Sperimentale, spento di default: renderer software di libmpv su `AVSampleBufferDisplayLayer`; niente HDR. Mai provato su dispositivo. |
| Sincronizzazione | 🟡 | Un file in una cartella scelta (iCloud Drive o altro): unisce libreria, cronologia, diario, collezioni, voti. Non è CloudKit. Mai provata con due dispositivi. |
| Inviti | ✅ | Fino a 6 al giorno, di default 4, con testi adatti all'ora. |
| Handoff | 🟡 | Dalla pagina titolo. |
| Backup con chiavi | ✅ | Ora anche Real-Debrid e le chiavi AI (solo se scegli di includerle). |
| Misurare il file prima di avviarlo | ☐ | HDR e audio restano dedotti dal nome. |
