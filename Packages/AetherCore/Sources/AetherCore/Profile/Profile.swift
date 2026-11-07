import Foundation

// MARK: Tastes

public enum TasteVerdict: String, Codable, Sendable {
    case like, dislike
}

/// A title the viewer judged in the taste game, with what is needed to show it again without asking anyone.
public struct TasteVote: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: String?
    public var year: String?
    public var genres: [String]
    public var verdict: TasteVerdict
    public var votedAt: Date

    public init(id: String, type: String, name: String, poster: String? = nil, year: String? = nil, genres: [String] = [],
                verdict: TasteVerdict, votedAt: Date = Date()) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.year = year
        self.genres = genres
        self.verdict = verdict
        self.votedAt = votedAt
    }
}

/// The genres the viewer can pick. `cinemeta` is how the addons spell it.
public enum ProfileGenre: String, CaseIterable, Codable, Sendable {
    case action, adventure, animation, comedy, crime, documentary, drama, family, fantasy, history, horror, music, mystery, romance, scifi, thriller, war, western

    public var title: String {
        switch self {
        case .action: return "Azione"
        case .adventure: return "Avventura"
        case .animation: return "Animazione"
        case .comedy: return "Commedia"
        case .crime: return "Crime"
        case .documentary: return "Documentari"
        case .drama: return "Drammatici"
        case .family: return "Famiglia"
        case .fantasy: return "Fantasy"
        case .history: return "Storici"
        case .horror: return "Horror"
        case .music: return "Musicali"
        case .mystery: return "Mistero"
        case .romance: return "Romantici"
        case .scifi: return "Fantascienza"
        case .thriller: return "Thriller"
        case .war: return "Guerra"
        case .western: return "Western"
        }
    }

    public var cinemeta: String {
        switch self {
        case .scifi: return "Sci-Fi"
        case .documentary: return "Documentary"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    public var emoji: String {
        switch self {
        case .action: return "💥"
        case .adventure: return "🧭"
        case .animation: return "🎨"
        case .comedy: return "😂"
        case .crime: return "🕵️"
        case .documentary: return "🎥"
        case .drama: return "🎭"
        case .family: return "👨‍👩‍👧"
        case .fantasy: return "🧙"
        case .history: return "🏛️"
        case .horror: return "👻"
        case .music: return "🎵"
        case .mystery: return "🔎"
        case .romance: return "💘"
        case .scifi: return "🚀"
        case .thriller: return "😰"
        case .war: return "🪖"
        case .western: return "🤠"
        }
    }

    /// The enum case for how a catalog spells a genre («Sci-Fi», «Action»…), or nil.
    public static func from(cinemeta name: String) -> ProfileGenre? {
        return ProfileGenre.allCases.first { $0.cinemeta.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public struct ProfileAvatar: Identifiable, Hashable, Sendable {
    public var id: String
    public var emoji: String
    /// Two colours (RRGGBB) of the gradient behind it.
    public var from: String
    public var to: String
}

public enum ProfileAvatars {
    public static let custom = "custom"

    public static let all: [ProfileAvatar] = [
        ProfileAvatar(id: "popcorn", emoji: "🍿", from: "FF9F1C", to: "E4572E"),
        ProfileAvatar(id: "clapper", emoji: "🎬", from: "4A4E69", to: "22223B"),
        ProfileAvatar(id: "reel", emoji: "🎞️", from: "00A6A6", to: "0B3954"),
        ProfileAvatar(id: "alien", emoji: "👽", from: "7BD389", to: "2D6A4F"),
        ProfileAvatar(id: "robot", emoji: "🤖", from: "5BC0EB", to: "3A506B"),
        ProfileAvatar(id: "ghost", emoji: "👻", from: "CDB4DB", to: "6D597A"),
        ProfileAvatar(id: "vampire", emoji: "🧛", from: "B5179E", to: "3C096C"),
        ProfileAvatar(id: "hero", emoji: "🦸", from: "F72585", to: "7209B7"),
        ProfileAvatar(id: "detective", emoji: "🕵️", from: "6C757D", to: "212529"),
        ProfileAvatar(id: "cowboy", emoji: "🤠", from: "D4A373", to: "7F5539"),
        ProfileAvatar(id: "ninja", emoji: "🥷", from: "495057", to: "0B090A"),
        ProfileAvatar(id: "dragon", emoji: "🐉", from: "EF476F", to: "7B2CBF"),
        ProfileAvatar(id: "dino", emoji: "🦖", from: "80B918", to: "2B9348"),
        ProfileAvatar(id: "astronaut", emoji: "🧑‍🚀", from: "4361EE", to: "10002B"),
        ProfileAvatar(id: "wizard", emoji: "🧙", from: "7400B8", to: "240046"),
        ProfileAvatar(id: "masks", emoji: "🎭", from: "FFD166", to: "EF476F"),
        ProfileAvatar(id: "rocket", emoji: "🚀", from: "48CAE4", to: "023E8A"),
        ProfileAvatar(id: "ticket", emoji: "🎟️", from: "F4A261", to: "264653"),
    ]

    public static func avatar(id: String) -> ProfileAvatar { return all.first { $0.id == id } ?? all[0] }
}

public struct ProfileSettings: Codable, Equatable, Sendable {
    public var name: String = ""
    /// A `ProfileAvatars` id, or `custom` (the photo the viewer chose, kept on the phone).
    public var avatar: String = "popcorn"
    /// `ProfileGenre` raw values.
    public var genres: [String] = []
    public var votes: [TasteVote] = []
    /// Titles passed over in the taste game without a verdict (not shown again for a while).
    public var skipped: [String] = []
    /// Occasional notifications that invite to watch something (never with the name when there is none).
    public var inviteNotifications: Bool = true
    /// Invitations a day (1...6).
    public var invitesPerDay: Int = 4

    public init() {}

    private enum CodingKeys: String, CodingKey { case name, avatar, genres, votes, skipped, inviteNotifications, invitesPerDay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = String((c.value(.name, default: "") as String).prefix(40))
        avatar = c.value(.avatar, default: "popcorn")
        genres = c.stringList(.genres)
        votes = c.lossyArray(TasteVote.self, forKey: .votes)
        skipped = Array(c.stringList(.skipped).suffix(400))
        inviteNotifications = c.value(.inviteNotifications, default: true)
        invitesPerDay = min(6, max(1, c.value(.invitesPerDay, default: 4) as Int))
    }

    /// The name to use in a greeting; nil when none was set.
    public var displayName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func verdict(for id: String) -> TasteVerdict? { return votes.first { $0.id == id }?.verdict }
    public var likes: [TasteVote] { return votes.filter { $0.verdict == .like }.sorted { $0.votedAt > $1.votedAt } }
    public var dislikes: [TasteVote] { return votes.filter { $0.verdict == .dislike }.sorted { $0.votedAt > $1.votedAt } }

    public mutating func vote(_ vote: TasteVote) {
        votes.removeAll { $0.id == vote.id }
        skipped.removeAll { $0 == vote.id }
        votes.append(vote)
    }

    public mutating func removeVote(id: String) { votes.removeAll { $0.id == id } }

    public mutating func skip(_ id: String) {
        skipped.removeAll { $0 == id }
        skipped.append(id)
        if skipped.count > 400 { skipped.removeFirst(skipped.count - 400) }
    }

    public mutating func toggleGenre(_ genre: ProfileGenre) {
        if genres.contains(genre.rawValue) { genres.removeAll { $0 == genre.rawValue } } else { genres.append(genre.rawValue) }
    }
}

/// A title offered by the taste game.
public struct TasteCandidate: Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: String?
    public var year: String?
    public var genres: [String]
    public var overview: String?
    public var cast: [String]

    public init(id: String, type: String, name: String, poster: String? = nil, year: String? = nil, genres: [String] = [], overview: String? = nil, cast: [String] = []) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.year = year
        self.genres = genres
        self.overview = overview
        self.cast = cast
    }
}

public enum TasteEngine {
    /// What may still be offered: no title already judged or passed over, none in `excluding`, no repeats, and only ones with a poster
    /// (a card without a picture is not a card).
    public static func deck(_ items: [TasteCandidate], profile: ProfileSettings, excluding: Set<String> = []) -> [TasteCandidate] {
        var seen = Set<String>(profile.votes.map { $0.id })
        seen.formUnion(profile.skipped)
        seen.formUnion(excluding)
        return items.filter { item in
            guard let poster = item.poster, !poster.isEmpty else { return false }
            return seen.insert(item.id).inserted
        }
    }

    /// The viewer's genres by weight: each like counts +1 and each dislike −1 for the genres of that title, and the genres they chose by
    /// hand start with +3. Genres that end up at zero or below are left out.
    public static func topGenres(_ profile: ProfileSettings, limit: Int = 5) -> [String] {
        var score: [String: Int] = [:]
        for genre in profile.genres { score[genre, default: 0] += 3 }
        for vote in profile.votes {
            for name in vote.genres {
                let key = ProfileGenre.from(cinemeta: name)?.rawValue ?? name
                score[key, default: 0] += vote.verdict == .like ? 1 : -1
            }
        }
        return score.filter { $0.value > 0 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map { $0.key }
    }
}

// MARK: Invitations (notifications)

public struct InviteSuggestion: Equatable, Sendable {
    public var id: String
    public var type: String
    public var name: String
    /// The genre (Italian) that makes it a good suggestion.
    public var genre: String

    public init(id: String, type: String, name: String, genre: String) {
        self.id = id
        self.type = type
        self.name = name
        self.genre = genre
    }
}

public struct InviteAlert: Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var fire: Date
    /// The title to open when the notification is tapped, if it suggests one.
    public var type: String?
    public var metaID: String?
}

public enum InvitePlanner {
    /// The times of day (hour, minute) for 1 to 6 invitations a day: spread over the day, never in the small hours.
    static func slots(perDay: Int) -> [(hour: Int, minute: Int)] {
        switch min(6, max(1, perDay)) {
        case 1: return [(20, 30)]
        case 2: return [(13, 0), (21, 0)]
        case 3: return [(9, 30), (16, 30), (21, 0)]
        case 4: return [(9, 30), (13, 0), (18, 0), (21, 30)]
        case 5: return [(8, 30), (11, 30), (15, 30), (19, 0), (22, 0)]
        default: return [(8, 30), (11, 0), (13, 30), (16, 30), (19, 30), (22, 0)]
        }
    }

    enum DayPart { case morning, lunch, afternoon, evening, night }

    static func part(hour: Int, minute: Int) -> DayPart {
        let t = hour * 60 + minute
        switch t {
        case ..<(12 * 60): return .morning
        case ..<(15 * 60): return .lunch
        case ..<(18 * 60 + 30): return .afternoon
        case ..<(21 * 60 + 15): return .evening
        default: return .night
        }
    }

    /// The lines for a moment of the day: each one fits the hour it is sent at.
    static func lines(part: DayPart, weekend: Bool) -> [String] {
        switch part {
        case .morning:
            return weekend ? ["Buongiorno! Colazione e un film?", "Sabato o domenica mattina: una serie con calma?"]
                           : ["Buongiorno! Cosa guardiamo oggi?", "Un episodio col caffè?"]
        case .lunch:
            return weekend ? ["Dopo pranzo c'è tutto il tempo per un film.", "Giorno perfetto per il binge watching."]
                           : ["Pausa pranzo: un episodio al volo?", "Hai mezz'ora? C'è una serie che ti aspetta."]
        case .afternoon:
            return weekend ? ["Pomeriggio libero: giorno perfetto per il binge watching.", "Cosa guardiamo questo pomeriggio?"]
                           : ["Pomeriggio no? Rimedia con un buon film.", "Quando finisci, il divano ti aspetta."]
        case .evening:
            return ["Serata film?", "Cosa guardiamo stasera?", "Il divano ti aspetta: scegli qualcosa da guardare."]
        case .night:
            return ["Ancora un episodio prima di dormire?", "Un ultimo film della giornata?", "Notte da cinema: cosa guardiamo?"]
        }
    }

    /// The invitations for the next `days` days (the system keeps at most 64 pending notifications, so the default horizon shrinks as the
    /// number a day grows). The name is used only when there is one. Slots less than 90 minutes away are skipped (the viewer has just
    /// opened the app), and every other invitation suggests a title when there is one to suggest.
    public static func plan(now: Date, name: String?, perDay: Int, suggestions: [InviteSuggestion], days: Int? = nil, calendar: Calendar = .current) -> [InviteAlert] {
        let slots = slots(perDay: perDay)
        let horizon = days ?? max(2, 40 / max(1, slots.count))
        let start = calendar.startOfDay(for: now)
        var alerts: [InviteAlert] = []
        var counter = 0
        for offset in 0..<max(0, horizon) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            for slot in slots {
                guard let fire = calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: day), fire > now.addingTimeInterval(90 * 60) else { continue }
                let dayPart = part(hour: slot.hour, minute: slot.minute)
                let id = "aether.invite.\(Int(fire.timeIntervalSince1970))"
                if !suggestions.isEmpty, counter % 2 == 1 {
                    let pick = suggestions[(counter / 2) % suggestions.count]
                    let lead: String
                    switch dayPart {
                    case .morning: lead = "Per iniziare bene la giornata"
                    case .lunch: lead = "Per la pausa"
                    case .afternoon: lead = "Per il pomeriggio"
                    case .evening: lead = "Per stasera"
                    case .night: lead = "Prima di dormire"
                    }
                    alerts.append(InviteAlert(id: id, title: name.map { "\($0), \(lead.lowercased())" } ?? lead, body: "«\(pick.name)» · per chi ama \(pick.genre.lowercased())",
                                              fire: fire, type: pick.type, metaID: pick.id))
                } else {
                    var pool = lines(part: dayPart, weekend: weekend).map { (title: "Aether", body: $0) }
                    if let name = name { pool.append((title: "Ehi \(name)", body: "Cosa guardiamo?")) }
                    let message = pool[(counter + offset) % pool.count]
                    alerts.append(InviteAlert(id: id, title: message.title, body: message.body, fire: fire, type: nil, metaID: nil))
                }
                counter += 1
            }
        }
        return alerts
    }
}

// MARK: Trailers

public enum YouTubeLink {
    /// The video id of a YouTube address (`watch?v=`, `youtu.be/`, `embed/`), or nil.
    public static func id(from url: URL) -> String? {
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        func clean(_ text: String?) -> String? {
            guard let text = text, text.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil else { return nil }
            return text
        }
        if host == "youtu.be" { return clean(url.pathComponents.dropFirst().first) }
        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") else { return nil }
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return clean(value) }
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "embed"), index + 1 < parts.count { return clean(parts[index + 1]) }
        return nil
    }
}
