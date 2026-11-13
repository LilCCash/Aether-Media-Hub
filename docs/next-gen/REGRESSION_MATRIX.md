# Matrice prima / dopo

| Modifica | Prima | Dopo | Test | Regressioni note | Rischio residuo |
|---|---|---|---|---|---|
| Limiter annullabile | Task annullati in coda ed eseguiti | Escono subito, non eseguono | ReliabilityFixTests ×3, ServiceTests | nessuna | — |
| Attesa addon limitata | Coda illimitata | ≤ 2× timeout in coda | testQueueWaitIsBoundedByMaxWait | nessuna; raffiche normali restano sotto i 30 s | Con >30 s di coda una richiesta ora fallisce (prima poteva bloccare la schermata) |
| Budget cache | Solo 400 voci | +48 MiB memoria, 256 MiB disco, 30 giorni | 3 test nuovi + MiscTests/MetadataTests | nessuna | Voci stale oltre 30 giorni senza uso non sono più servibili offline |
| HTTPClient lock | Lettura fuori lock | Lettura sotto lock | TSan 0 avvisi | nessuna | — |
| DNS fail-closed | Errore DNS ignorato | Rifiutato (rete locale vietata) dopo 1 retry | NetworkTests | nessuna nei test | Resolver di sistema rotto ma URLSession funzionante (raro) → addon non raggiungibile |
| LiveRemux | Chiusura garantita dal chiamante | Garantita anche da `start()` | build CI | nessuna | — |
| ImageLoader | Segnaposto con file corrotto | Riscaricato subito, una volta | ImageLoaderTests ×2 nuovi | nessuna | — |
| Decodifica immagini | Nell'actor, una alla volta | Fuori, max 3 | ImageLoaderTests esistenti | nessuna nei test | Da misurare con Instruments |
| MIME relay | m4a/ac3/ec3/webvtt come octet-stream | Tipi corretti | AdaptiveRelayHLSTests | nessuna | — |
| Ricerca impostazioni | Assente | Presente | SettingsIndexTests | nessuna | Indice da aggiornare quando si aggiungono opzioni |
| Hero adattivo | 430/560 pt fissi | Uguale ≥ 6,1″, più basso sugli schermi bassi | UI test Layout | da vedere sugli screenshot | Aspetto su SE da verificare a occhio |
| Carosello + VoiceOver | Scorreva da solo | Fermo | — | nessuna | — |
| Nota tracce cast | Nessuna spiegazione | Nota | — | nessuna | — |
| CI screenshot | Ogni branch sovrascriveva `ci-screenshots` | Solo `aether-swift-features` pubblica; gli altri caricano un artifact | run CI | nessuna | — |
