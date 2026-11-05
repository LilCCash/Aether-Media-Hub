import Foundation

/// A famous line, with the film it comes from (the IMDb id opens its page in the app). Lines are written as the Italian edition gives
/// them as far as I remember them: a few may differ by a word.
struct FilmQuote: Equatable {
    let text: String
    let film: String
    let id: String
    let type: String

    init(_ text: String, _ film: String, _ id: String, type: String = "movie") {
        self.text = text
        self.film = film
        self.id = id
        self.type = type
    }
}

enum Quotes {
    static let all: [FilmQuote] = [
        FilmQuote("Francamente, me ne infischio.", "Via col vento", "tt0031381"),
        FilmQuote("Gli farò un'offerta che non potrà rifiutare.", "Il padrino", "tt0068646"),
        FilmQuote("Tieni i tuoi amici vicini, ma i tuoi nemici ancora più vicini.", "Il padrino - Parte II", "tt0071562"),
        FilmQuote("Suonala ancora, Sam.", "Casablanca", "tt0034583"),
        FilmQuote("Che la Forza sia con te.", "Guerre stellari", "tt0076759"),
        FilmQuote("Io sono tuo padre.", "L'Impero colpisce ancora", "tt0080684"),
        FilmQuote("Tornerò.", "Terminator", "tt0088247"),
        FilmQuote("Dici a me?", "Taxi Driver", "tt0075314"),
        FilmQuote("Houston, abbiamo un problema.", "Apollo 13", "tt0112384"),
        FilmQuote("Verso l'infinito e oltre!", "Toy Story", "tt0114709"),
        FilmQuote("Perché così serio?", "Il cavaliere oscuro", "tt0468569"),
        FilmQuote("Il mio tesssoro.", "Il Signore degli Anelli - Le due torri", "tt0167261"),
        FilmQuote("Non si può passare!", "Il Signore degli Anelli - La compagnia dell'anello", "tt0120737"),
        FilmQuote("La vita è come una scatola di cioccolatini: non sai mai quello che ti capita.", "Forrest Gump", "tt0109830"),
        FilmQuote("Vedo la gente morta.", "Il sesto senso", "tt0167404"),
        FilmQuote("Salutate il mio piccolo amico!", "Scarface", "tt0086250"),
        FilmQuote("Ci serve una barca più grossa.", "Lo squalo", "tt0073195"),
        FilmQuote("Sono il re del mondo!", "Titanic", "tt0120338"),
        FilmQuote("Nessuno mette Baby in un angolo.", "Dirty Dancing", "tt0092890"),
        FilmQuote("Strade? Dove andiamo noi non c'è bisogno di strade.", "Ritorno al futuro", "tt0088763"),
        FilmQuote("Carpe diem. Cogliete l'attimo, ragazzi.", "L'attimo fuggente", "tt0097165"),
        FilmQuote("Continua a nuotare.", "Alla ricerca di Nemo", "tt0266543"),
        FilmQuote("Non c'è posto come casa propria.", "Il mago di Oz", "tt0032138"),
        FilmQuote("Hakuna Matata!", "Il re leone", "tt0110357"),
        FilmQuote("Buongiorno, principessa!", "La vita è bella", "tt0118799"),
        FilmQuote("Pillola rossa o pillola blu?", "Matrix", "tt0133093"),
        FilmQuote("Sento la necessità, la necessità di velocità!", "Top Gun", "tt0092099"),
        FilmQuote("Fammi vedere i soldi!", "Jerry Maguire", "tt0116695"),
        FilmQuote("Chi chiamerai?", "Ghostbusters", "tt0087332"),
        FilmQuote("Adriana!", "Rocky", "tt0075148"),
        FilmQuote("Ecco Johnny!", "Shining", "tt0081505"),
        FilmQuote("Al mio segnale, scatenate l'inferno.", "Il gladiatore", "tt0172495"),
        FilmQuote("Tutti quei momenti andranno perduti nel tempo, come lacrime nella pioggia.", "Blade Runner", "tt0083658"),
        FilmQuote("Mi dispiace, Dave. Temo di non poterlo fare.", "2001: Odissea nello spazio", "tt0062622"),
        FilmQuote("Nello spazio nessuno può sentirti urlare.", "Alien", "tt0078748"),
        FilmQuote("La prima regola del Fight Club è: non parlare mai del Fight Club.", "Fight Club", "tt0137523"),
    ]

    /// The line shown at `date`: it changes every three hours, and `offset` is how many steps the viewer moved by hand.
    static func index(at date: Date, offset: Int, count: Int = Quotes.all.count) -> Int {
        guard count > 0 else { return 0 }
        let slot = Int(date.timeIntervalSince1970 / (3 * 3600))
        return ((slot + offset) % count + count) % count
    }
}
