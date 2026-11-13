import Foundation

/// What the settings search can find: every settings page with the options it holds, written the way they are labelled
/// on screen. Matching ignores case and accents, and every word typed must appear.
enum SettingsIndex {
    enum Page: String, CaseIterable {
        case appearance, playback, sourceScoring, addons, content, liveTV, advancedSearch, indexing
        case services, trakt, sync, account, casting, storage, extras, advanced, about

        var title: String {
            switch self {
            case .appearance: return "Aspetto"
            case .playback: return "Riproduzione"
            case .sourceScoring: return "Intelligenza delle fonti"
            case .addons: return "Addon"
            case .content: return "Cataloghi e scoperta"
            case .liveTV: return "Live TV"
            case .advancedSearch: return "Ricerca avanzata"
            case .indexing: return "Indicizzazione"
            case .services: return "Servizi e chiavi"
            case .trakt: return "Trakt"
            case .sync: return "Sincronizzazione"
            case .account: return "Account e dati"
            case .casting: return "Casting"
            case .storage: return "Archiviazione"
            case .extras: return "Funzioni extra"
            case .advanced: return "Avanzate"
            case .about: return "Informazioni e licenze"
            }
        }
    }

    struct Hit: Identifiable, Equatable {
        let title: String
        let page: Page
        var id: String { page.rawValue + "." + title }
    }

    /// (option, page). The page title itself is always searchable too.
    static let entries: [(String, Page)] = [
        ("Tema chiaro e scuro", .appearance), ("Colore di accento", .appearance), ("Preset grafici", .appearance),
        ("Sfondo", .appearance), ("Stile delle schede", .appearance), ("Angoli arrotondati", .appearance),
        ("Carattere dei titoli", .appearance), ("Animazioni", .appearance), ("Home: layout Classica o Vetrina", .appearance),
        ("Home: sezioni, ordine e dimensioni", .appearance), ("Carosello in alto (hero)", .appearance),
        ("Scorrimento automatico del carosello", .appearance), ("Riduci effetti", .appearance), ("Transizioni", .appearance),
        ("Carosello più basso sugli schermi piccoli", .appearance), ("Scopri nella barra in basso (Vetrina)", .appearance),
        ("Ombra sotto i testi sulle immagini", .appearance), ("Filtri rapidi nelle sorgenti", .appearance),
        ("Ricerca nelle impostazioni", .appearance), ("Impostazioni essenziali", .appearance), ("Stile Bilanciato", .appearance),
        ("Modalità Cinema", .playback), ("Motore del player (AVPlayer o MPV)", .playback), ("Righe delle sorgenti e badge", .playback),
        ("Stato dei player e dello schermo", .playback), ("HDR e Dolby Vision", .playback), ("Immagine (MPV)", .playback),
        ("Ripresa della riproduzione", .playback), ("Controlli e gesti del player", .playback), ("Velocità di riproduzione", .playback),
        ("Cambio episodio", .playback), ("Prossimo episodio automatico", .playback), ("Salta intro e riassunto", .playback),
        ("LiveContainer", .playback), ("Lingua audio preferita", .playback), ("Lingua dei sottotitoli", .playback),
        ("Stile dei sottotitoli", .playback), ("Ordine delle sorgenti", .playback),
        ("Audio in background", .playback), ("Picture in Picture", .playback), ("Converti i file MKV per AVPlayer", .playback),
        ("Punteggio delle sorgenti", .sourceScoring), ("Scelta automatica della sorgente", .sourceScoring),
        ("Installa un addon", .addons), ("Ordine degli addon", .addons),
        ("Cataloghi: nome, ordine e visibilità", .content), ("Categorie di Scopri", .content),
        ("Aggiornamento dei cataloghi", .content), ("Lingua di trama e dettagli", .content), ("Cronologia", .content),
        ("Playlist e guida TV (XMLTV)", .liveTV), ("Filtri di ricerca", .advancedSearch), ("Indice locale", .indexing),
        ("Chiave TMDB", .services), ("TVDB", .services), ("TorBox (debrid)", .services), ("OpenSubtitles", .services),
        ("Fanart (loghi)", .services), ("IntroDB", .services),
        ("Accesso a Trakt", .trakt), ("Scrobbling", .trakt), ("iCloud", .sync), ("Backup e ripristino", .account),
        ("Esporta i dati", .account),
        ("Google Cast", .casting), ("DLNA e televisori", .casting), ("AirPlay", .casting), ("Ponte per il cast", .casting),
        ("Converti MKV per Google Cast", .casting),
        ("Spazio utilizzato", .storage), ("Svuota la cache", .storage), ("Download", .storage),
        ("Scarica una stagione", .storage), ("Log del downloader", .storage),
        ("Widget", .extras), ("Watch Together (SharePlay)", .extras),
        ("Registro diagnostico", .advanced), ("Rete locale", .advanced),
        ("Versione e licenze", .about),
    ]

    static func search(_ query: String) -> [Hit] {
        let words = fold(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var hits: [Hit] = []
        var seen = Set<String>()
        let all = Page.allCases.map { ($0.title, $0) } + entries
        for (title, page) in all {
            let haystack = fold(title + " " + page.title)
            guard words.allSatisfy({ haystack.contains($0) }) else { continue }
            let hit = Hit(title: title, page: page)
            if seen.insert(hit.id).inserted { hits.append(hit) }
        }
        return hits
    }

    static func fold(_ text: String) -> String {
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "it_IT")).lowercased()
    }
}
