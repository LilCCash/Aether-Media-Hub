# Sottotitoli e accessibilità

**Fonti.** README di media_kit (sezioni «Customize subtitles», «Load external subtitle track»), documentazione Apple su tracce e sottotitoli (vedi scheda iOS), OpenSubtitles — https://api.opensubtitles.com/api/v1/ **non raggiungibile**.
Aether non chiama direttamente OpenSubtitles: i sottotitoli arrivano **dagli addon** (risorsa `subtitles` del protocollo Stremio) e dalle tracce incorporate.

**Scelte.**
- Tracce incorporate (MKV/MP4): selezione e stile dal motore (libmpv). Sottotitoli esterni da addon: scaricati da `SubtitleLoader` (≤ 3 MB, UTF-8 con ripiego Latin-1, host validati), letti da `SubtitleParser` (**SRT, WebVTT**, testo di **ASS/SSA** senza stili) e disegnati da Aether con sincronia regolabile in entrambi i sensi (±30 s, passi da 0,25 s).
- Preferenze persistenti: lingua audio, lingua sottotitoli, attivazione di default, dimensione, rimozione delle descrizioni per non udenti (`[porta che sbatte]`, `JOHN:`, `♪`).
- Regola della lingua: se l'audio scelto è già nella lingua dei sottotitoli, si attivano solo i sottotitoli «forzati».
- Accessibilità: ogni pulsante ha etichetta semantica e area ≥ 44 px; i testi seguono la scala di sistema; «Riduci gli effetti» elimina blur e animazioni.

**Non supportato (dichiarato).** PGS, VobSub e ASS stilizzato per i file **esterni** (per quelli incorporati decide libmpv, non verificato). Nessun supporto VoiceOver/TalkBack provato su dispositivo.
**Verificato.** Parser, offset, pulizia, caricamento, preferenze: `test/domain_test.dart`, `test/player_session_test.dart`.
