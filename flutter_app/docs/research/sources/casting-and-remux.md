# Casting e remux

**Fonti.** AVRoutePickerView e AVPictureInPictureController (Apple, HTTP 200, solo titolo estratto); Google Cast Android sender — https://developers.google.com/cast/docs/android_sender **non raggiungibile**.
Nel repository: `docs/10-PONTE-E-CONVERSIONE.md` (ponte, remux FFmpeg e Cast dell'app iOS).

**Stato.** **Nessuna funzione di casting né di remux è implementata in Aether Flutter.** I pulsanti non esistono (niente comandi finti).
- AirPlay video: richiede AVPlayer; con libmpv trasmette al più l'audio (dichiarato anche dalla versione iOS dell'app). Da fare: adapter AVPlayer.
- Google Cast: richiede il Cast SDK con un ricevitore; non integrato. Un TV può non riprodurre MKV/Dolby Vision: servirebbe il **remux senza ricodifica** (come nel ponte iOS) e un server locale protetto. La transcodifica completa è fuori portata.
- Mirroring dello schermo, AirPlay e Cast nativo sono cose diverse e non vanno confuse nell'interfaccia.

**Lavoro residuo.** Porting del ponte/remux in Dart o via FFmpeg nativo; vedi docs/LIMITATIONS.md.
