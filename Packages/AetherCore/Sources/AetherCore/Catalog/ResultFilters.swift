import Foundation

// Local (client-side) filters for lists of `MetaItem`. They exist because most addons cannot filter a search by
// year or rating, and many cannot filter it by genre. Nothing here pretends to be server-side: the UI applies these
// filters to the items it already received and says how many were hidden because the data to decide was missing.

// MARK: - Genre names

/// Helpers to compare and merge genre names coming from different addons ("Action", "action", " ACTION ").
public enum GenreNames {
    /// Display form: surrounding whitespace removed, inner whitespace runs collapsed to one space.
    public static func clean(_ genre: String) -> String {
        return genre.split(whereSeparator: { (character: Character) -> Bool in character.isWhitespace })
            .joined(separator: " ")
    }

    /// Comparison key: `clean` plus case and diacritics folded.
    public static func key(_ genre: String) -> String {
        let folded = genre.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return clean(folded)
    }

    /// True when `genres` contains `genre` ignoring case, diacritics and surrounding whitespace.
    public static func contains(_ genres: [String], _ genre: String) -> Bool {
        let wanted = GenreNames.key(genre)
        if wanted.isEmpty { return false }
        return genres.contains(where: { (candidate: String) -> Bool in GenreNames.key(candidate) == wanted })
    }

    /// Union of several genre lists: blank entries dropped, duplicates (by `key`) removed keeping the first
    /// spelling met, result sorted by `key`. Deterministic: independent of dictionary ordering and locale.
    public static func mergedSorted(_ lists: [[String]]) -> [String] {
        var spelling: [String: String] = [:]
        for list in lists {
            for raw in list {
                let normalised = GenreNames.key(raw)
                if normalised.isEmpty { continue }
                if spelling[normalised] == nil {
                    spelling[normalised] = GenreNames.clean(raw)
                }
            }
        }
        var result: [String] = []
        for normalised in spelling.keys.sorted() {
            if let display = spelling[normalised] {
                result.append(display)
            }
        }
        return result
    }

    /// The genres actually carried by `items` (same rules as `mergedSorted`). Useful to offer a local genre filter
    /// built from the results on screen when no catalog declares a genre list.
    public static func present(in items: [MetaItem]) -> [String] {
        var lists: [[String]] = []
        for item in items {
            lists.append(item.genres)
        }
        return mergedSorted(lists)
    }
}

// MARK: - Release years

/// The years an item covers, parsed from `releaseInfo` ("2019", "2011-2019", "2019–") or, failing that, `released`.
public struct ReleaseYears: Equatable, Hashable, Sendable {
    /// First (premiere) year.
    public var start: Int
    /// Last year of the run; equals `start` for a single year or an open-ended run.
    public var end: Int
    /// "2019–": the run has no declared end.
    public var isOngoing: Bool

    /// Years outside this range are not treated as release years ("1080p" must not become the year 1080).
    public static let plausibleRange: ClosedRange<Int> = 1870...2100

    public init(start: Int, end: Int? = nil, isOngoing: Bool = false) {
        self.start = start
        if let end = end, end > start {
            self.end = end
        } else {
            self.end = start
        }
        self.isOngoing = isOngoing
    }

    /// Last year the item may still be part of; `Int.max` while ongoing.
    public var lastYear: Int {
        return isOngoing ? Int.max : end
    }

    public var isSingleYear: Bool {
        return !isOngoing && start == end
    }

    private struct YearToken {
        var start: Int
        var end: Int
        var year: Int
    }

    /// Parses release info as addons write it. Returns nil when no plausible 4-digit year is present.
    ///
    /// - "2019" -> 2019
    /// - "2011-2019", "2011 – 2019", "2011—2019" -> 2011 through 2019
    /// - "2019–", "2019-", "(2019 - )" -> 2019, ongoing
    /// - "2019-05-12" (a date) -> 2019 only; "2019-2011" (reversed) -> 2019 only
    /// - "N/A", "", "1080p", "12345" -> nil
    public static func parse(_ text: String?) -> ReleaseYears? {
        guard let text = text else { return nil }
        let scalars = Array(text.unicodeScalars)
        let tokens = yearTokens(in: scalars)
        guard let first = tokens.first else { return nil }

        let dashIndex = skipSpaces(scalars, from: first.end)
        guard dashIndex < scalars.count, isDash(scalars[dashIndex]) else {
            return ReleaseYears(start: first.year)
        }
        let afterDash = skipSpaces(scalars, from: dashIndex + 1)
        let second = tokens.first(where: { (token: YearToken) -> Bool in token.start == afterDash })
        if let second = second {
            return ReleaseYears(start: first.year, end: second.year)
        }
        if !hasAlphanumeric(scalars, from: afterDash) {
            return ReleaseYears(start: first.year, end: nil, isOngoing: true)
        }
        return ReleaseYears(start: first.year)
    }

    /// The years of an item: `releaseInfo` first, then the year of `released` (UTC, so the result does not
    /// depend on the device time zone).
    public static func of(_ item: MetaItem) -> ReleaseYears? {
        if let parsed = parse(item.releaseInfo) { return parsed }
        if let released = item.released {
            var calendar = Calendar(identifier: .gregorian)
            if let utc = TimeZone(identifier: "UTC") {
                calendar.timeZone = utc
            }
            let year = calendar.component(.year, from: released)
            if plausibleRange.contains(year) {
                return ReleaseYears(start: year)
            }
        }
        return nil
    }

    // MARK: Scanning

    private static func yearTokens(in scalars: [Unicode.Scalar]) -> [YearToken] {
        var tokens: [YearToken] = []
        var index = 0
        while index < scalars.count {
            if isDigit(scalars[index]) {
                var next = index
                var value = 0
                while next < scalars.count && isDigit(scalars[next]) {
                    // Only the first five digits matter; a longer run is rejected below anyway.
                    if next - index < 5 {
                        let digit = Int(scalars[next].value) - 48
                        value = value * 10 + digit
                    }
                    next += 1
                }
                if next - index == 4 && plausibleRange.contains(value) {
                    tokens.append(YearToken(start: index, end: next, year: value))
                }
                index = next
            } else {
                index += 1
            }
        }
        return tokens
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        return scalar.value >= 48 && scalar.value <= 57
    }

    /// Hyphen-minus, the Unicode hyphens and dashes (U+2010...U+2015) and the minus sign.
    private static func isDash(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2D, 0x2010...0x2015, 0x2212:
            return true
        default:
            return false
        }
    }

    private static func skipSpaces(_ scalars: [Unicode.Scalar], from index: Int) -> Int {
        var cursor = index
        while cursor < scalars.count && CharacterSet.whitespacesAndNewlines.contains(scalars[cursor]) {
            cursor += 1
        }
        return cursor
    }

    private static func hasAlphanumeric(_ scalars: [Unicode.Scalar], from index: Int) -> Bool {
        var cursor = index
        while cursor < scalars.count {
            if CharacterSet.alphanumerics.contains(scalars[cursor]) { return true }
            cursor += 1
        }
        return false
    }
}

/// How a `YearFilter` is compared with the years of a series that ran over several years.
public enum YearMatch: String, Codable, CaseIterable, Sendable {
    /// Only the premiere year counts (consistent with `MetaItem.year` and `SearchSort.yearDescending`).
    case premiere
    /// The item matches when any year of its run falls inside the filter ("2011-2019" matches 2015).
    case overlapping
}

/// An exact year, a closed range, or an open-ended range.
public struct YearFilter: Equatable, Hashable, Sendable {
    /// Inclusive; nil means "no lower limit".
    public var lowerBound: Int?
    /// Inclusive; nil means "no upper limit".
    public var upperBound: Int?

    /// Reversed bounds are swapped.
    public init(lowerBound: Int?, upperBound: Int?) {
        var low = lowerBound
        var high = upperBound
        if let candidateLow = low, let candidateHigh = high, candidateLow > candidateHigh {
            low = candidateHigh
            high = candidateLow
        }
        self.lowerBound = low
        self.upperBound = high
    }

    public static func exact(_ year: Int) -> YearFilter {
        return YearFilter(lowerBound: year, upperBound: year)
    }

    public static func range(_ first: Int, _ second: Int) -> YearFilter {
        return YearFilter(lowerBound: first, upperBound: second)
    }

    /// "dal 2010": no upper limit.
    public static func since(_ year: Int) -> YearFilter {
        return YearFilter(lowerBound: year, upperBound: nil)
    }

    /// "fino al 2010": no lower limit.
    public static func through(_ year: Int) -> YearFilter {
        return YearFilter(lowerBound: nil, upperBound: year)
    }

    /// The decade that contains `year`: 1994 gives 1990...1999.
    public static func decade(containing year: Int) -> YearFilter {
        let first = (year / 10) * 10
        return YearFilter(lowerBound: first, upperBound: first + 9)
    }

    /// Both limits missing: matches everything, so it is treated as "no year filter".
    public var isUnbounded: Bool {
        return lowerBound == nil && upperBound == nil
    }

    public func contains(_ year: Int) -> Bool {
        if let low = lowerBound, year < low { return false }
        if let high = upperBound, year > high { return false }
        return true
    }

    public func matches(_ years: ReleaseYears, mode: YearMatch) -> Bool {
        switch mode {
        case .premiere:
            return contains(years.start)
        case .overlapping:
            if let low = lowerBound, years.lastYear < low { return false }
            if let high = upperBound, years.start > high { return false }
            return true
        }
    }

    /// Short Italian label: "2019", "2011–2019", "dal 2011", "fino al 2019".
    public var label: String {
        if let low = lowerBound, let high = upperBound {
            return low == high ? "\(low)" : "\(low)–\(high)"
        }
        if let low = lowerBound { return "dal \(low)" }
        if let high = upperBound { return "fino al \(high)" }
        return "Tutti gli anni"
    }
}

// MARK: - Filtering

/// Result of applying `ResultFilters` to a list.
public struct ResultFilterOutcome: Equatable, Sendable {
    /// Items that passed every active filter, in their original order.
    public var kept: [MetaItem]
    /// Distinct items hidden only because the data needed to judge them is missing (and no active filter
    /// rejected them on data they do have).
    public var hiddenMissingData: Int
    /// Items hidden because an active filter rejected data they do carry.
    public var hiddenMismatch: Int
    /// Of `hiddenMissingData`: how many lack a release year. An item lacking several kinds of data is counted in
    /// each, so these three may add up to more than `hiddenMissingData`.
    public var hiddenWithoutYear: Int
    public var hiddenWithoutGenre: Int
    public var hiddenWithoutRating: Int

    public init(kept: [MetaItem], hiddenMissingData: Int = 0, hiddenMismatch: Int = 0,
                hiddenWithoutYear: Int = 0, hiddenWithoutGenre: Int = 0, hiddenWithoutRating: Int = 0) {
        self.kept = kept
        self.hiddenMissingData = hiddenMissingData
        self.hiddenMismatch = hiddenMismatch
        self.hiddenWithoutYear = hiddenWithoutYear
        self.hiddenWithoutGenre = hiddenWithoutGenre
        self.hiddenWithoutRating = hiddenWithoutRating
    }

    public var totalHidden: Int {
        return hiddenMissingData + hiddenMismatch
    }

    /// One Italian sentence per kind of missing data, e.g. "3 risultati senza anno nascosti".
    public var missingDataMessages: [String] {
        var messages: [String] = []
        if hiddenWithoutYear > 0 {
            messages.append(ResultFilterOutcome.message(count: hiddenWithoutYear, missing: "anno"))
        }
        if hiddenWithoutGenre > 0 {
            messages.append(ResultFilterOutcome.message(count: hiddenWithoutGenre, missing: "genere"))
        }
        if hiddenWithoutRating > 0 {
            messages.append(ResultFilterOutcome.message(count: hiddenWithoutRating, missing: "valutazione"))
        }
        return messages
    }

    /// The messages joined for a single footnote; nil when nothing was hidden for missing data.
    public var missingDataSummary: String? {
        let messages = missingDataMessages
        if messages.isEmpty { return nil }
        return messages.joined(separator: " · ")
    }

    static func message(count: Int, missing: String) -> String {
        if count == 1 {
            return "1 risultato senza \(missing) nascosto"
        }
        return "\(count) risultati senza \(missing) nascosti"
    }

    /// Sums several outcomes (for instance one per catalog row): kept items are concatenated in order.
    public static func combine(_ outcomes: [ResultFilterOutcome]) -> ResultFilterOutcome {
        var total = ResultFilterOutcome(kept: [])
        for outcome in outcomes {
            total.kept.append(contentsOf: outcome.kept)
            total.hiddenMissingData += outcome.hiddenMissingData
            total.hiddenMismatch += outcome.hiddenMismatch
            total.hiddenWithoutYear += outcome.hiddenWithoutYear
            total.hiddenWithoutGenre += outcome.hiddenWithoutGenre
            total.hiddenWithoutRating += outcome.hiddenWithoutRating
        }
        return total
    }
}

/// Client-side filters on year, genre and minimum rating. A filter that is nil/blank/zero is inactive.
///
/// An item that lacks the data a filter needs (no year, no genres, no usable rating) is hidden, not guessed
/// about, and counted in `ResultFilterOutcome` so the UI can tell the user.
public struct ResultFilters: Equatable, Sendable {
    public var year: YearFilter?
    public var yearMatch: YearMatch
    /// Compared ignoring case and diacritics against the item's `genres`.
    public var genre: String?
    /// 0...10; values above 10 are treated as 10, NaN/negative/zero as "no filter".
    public var minimumRating: Double?

    public init(year: YearFilter? = nil, yearMatch: YearMatch = .premiere, genre: String? = nil,
                minimumRating: Double? = nil) {
        self.year = year
        self.yearMatch = yearMatch
        self.genre = genre
        self.minimumRating = minimumRating
    }

    public static let none = ResultFilters()

    private var activeYear: YearFilter? {
        guard let filter = year, !filter.isUnbounded else { return nil }
        return filter
    }

    private var activeGenreKey: String? {
        guard let genre = genre else { return nil }
        let key = GenreNames.key(genre)
        return key.isEmpty ? nil : key
    }

    private var activeRatingFloor: Double? {
        guard let value = minimumRating, value.isFinite, value > 0 else { return nil }
        return min(value, 10)
    }

    public var isActive: Bool {
        return activeYear != nil || activeGenreKey != nil || activeRatingFloor != nil
    }

    /// The usable rating of an item: finite and in (0, 10]. Zero means "unrated" for several addons.
    public static func rating(of item: MetaItem) -> Double? {
        guard let value = item.ratingValue, value.isFinite, value > 0, value <= 10 else { return nil }
        return value
    }

    /// Applies every active filter. An item is kept when it passes all of them. Otherwise:
    /// - if some filter rejects data the item does have, it counts as a mismatch;
    /// - else (it only lacks data) it counts as hidden for missing data, once per kind of missing data.
    public func apply(to items: [MetaItem]) -> ResultFilterOutcome {
        let yearFilter = activeYear
        let genreKey = activeGenreKey
        let ratingFloor = activeRatingFloor
        if yearFilter == nil && genreKey == nil && ratingFloor == nil {
            return ResultFilterOutcome(kept: items)
        }

        var outcome = ResultFilterOutcome(kept: [])
        for item in items {
            var rejected = false
            var missingYear = false
            var missingGenre = false
            var missingRating = false

            if let filter = yearFilter {
                if let years = ReleaseYears.of(item) {
                    if !filter.matches(years, mode: yearMatch) { rejected = true }
                } else {
                    missingYear = true
                }
            }

            if let wanted = genreKey {
                var itemKeys = Set<String>()
                for genre in item.genres {
                    let key = GenreNames.key(genre)
                    if !key.isEmpty { itemKeys.insert(key) }
                }
                if itemKeys.isEmpty {
                    missingGenre = true
                } else if !itemKeys.contains(wanted) {
                    rejected = true
                }
            }

            if let floor = ratingFloor {
                if let rating = ResultFilters.rating(of: item) {
                    if rating < floor { rejected = true }
                } else {
                    missingRating = true
                }
            }

            if rejected {
                outcome.hiddenMismatch += 1
            } else if missingYear || missingGenre || missingRating {
                outcome.hiddenMissingData += 1
                if missingYear { outcome.hiddenWithoutYear += 1 }
                if missingGenre { outcome.hiddenWithoutGenre += 1 }
                if missingRating { outcome.hiddenWithoutRating += 1 }
            } else {
                outcome.kept.append(item)
            }
        }
        return outcome
    }
}
