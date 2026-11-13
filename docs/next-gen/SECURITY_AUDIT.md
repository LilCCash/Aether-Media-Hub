# Audit di sicurezza e privacy

| Area | Stato | Dettaglio |
|---|---|---|
| Chiavi e token | Buono | Portachiavi (`KeychainSecretStore`, test dedicati); nessuna chiave nel repository |
| Chiavi nella cache | Buono | Le chiavi della cache sono URL con possibili segreti degli addon: in memoria e su disco si usa solo l'hash SHA-256 (test esistente) |
| URL degli addon | Buono | `NetworkPolicy`: schema, lunghezza, IP privati/loopback/multicast, HTTPS obbligatorio per host pubblici, redirect rivalidati (max 5, niente declassamento https→http) |
| DNS rebinding (SECURITY-01) | **Rafforzato** | Prima: errore del resolver ignorato. Ora: con la rete locale vietata, un nome non risolvibile dopo un secondo tentativo viene rifiutato. Resta una finestra TOCTOU tra verifica e connessione (URLSession risolve di nuovo): chiuderla richiederebbe connettersi all'IP verificato, cosa che rompe SNI/HTTPS con le CDN. Rischio residuo accettato e documentato |
| Relay (ponte per il cast) | Buono | Token casuale a 256 bit nel percorso, nessun URL d'origine verso il ricevitore (test `AdaptiveRelayHLSTests`), `UpstreamGuard` già fail-closed sul DNS, sessioni a scadenza |
| Playlist cifrate / DRM | Buono | SAMPLE-AES, KEYFORMAT non identity, `EXT-X-DEFINE`, steering e DASH con DRM vengono rifiutati invece di esporre URL |
| Log | Da mantenere | Registro diagnostico locale; nessuna telemetria remota. Nessuna modifica introdotta qui |
| Telemetria | Assente | Nessuna metrica inviata all'esterno; MetricKit resta locale |

Threat model sintetico: addon e sorgenti non sono fidati (possono puntare alla LAN o a metadati cloud), il ricevitore in
LAN è semi-fidato (vede solo il token di sessione), l'utente è fidato. Le protezioni sopra coprono SSRF dagli addon e
fuga di URL/credenziali verso i televisori.
