import Foundation

// Pure file selection for a TorBox torrent: given the files `mylist` reports and what the stream tells us (file name hint,
// Stremio video id, size, `fileIdx`), decide which file to ask `requestdl` for.
//
// Order (docs/research/torbox-api.md sections 5 and 7.6):
//   1. only video files that are neither zipped nor infected are candidates;
//   2. `behaviorHints.filename`, compared exactly and then normalised the way Torrentio does (`&` -> `and`, everything that is
//      not a letter or digit dropped, Unicode composed);
//   3. for an episode: the season/episode parsed from the file name (SxxExx, S01.E02, 1x02, "Season 1 Episode 2", a season
//      folder plus Exx...). No confident match -> `noConfidentMatch` with the candidate list, never "the largest";
//   4. for a movie: the largest video file.
// Stremio's `fileIdx` is NOT the provider's file id. It is used only as a tie-breaker, as a position in the `files` array.

public enum TorBoxFileMatcher {
    public struct Query: Equatable, Sendable {
        public var filename: String?
        public var episode: DebridEpisode?
        /// The video id looked like a series episode (also true when `episode` could not be parsed from it).
        public var expectsEpisode: Bool
        public var fileIndexHint: Int?
        public var sizeHint: Int64?

        public init(filename: String? = nil, episode: DebridEpisode? = nil, expectsEpisode: Bool = false,
                    fileIndexHint: Int? = nil, sizeHint: Int64? = nil) {
            self.filename = filename
            self.episode = episode
            self.expectsEpisode = expectsEpisode || episode != nil
            self.fileIndexHint = fileIndexHint
            self.sizeHint = sizeHint
        }
    }

    public enum Reason: String, Sendable {
        case filenameHint
        case episodeNumber
        case largestVideo
        /// The torrent has a single usable video file and nothing contradicts it.
        case onlyVideo
    }

    public enum Outcome: Equatable, Sendable {
        case selected(TorBoxFile, Reason)
        case noConfidentMatch([DebridFileCandidate])
        case noVideo
        case archivesOnly
        case infectedOnly
    }

    public static func query(for request: DebridRequest) -> Query {
        let episode = DebridEpisode.parse(stremioID: request.stremioID)
        let expects = episode != nil || DebridEpisode.expectsEpisode(stremioID: request.stremioID)
        return Query(filename: request.filename, episode: episode, expectsEpisode: expects,
                     fileIndexHint: request.fileIndex, sizeHint: request.videoSize)
    }

    // MARK: Selection

    struct Entry {
        let file: TorBoxFile
        let id: Int
        /// Position in the array TorBox returned (what Stremio's `fileIdx` might refer to).
        let position: Int
        let size: Int64
        let tag: EpisodeTag?
    }

    public static func select(from files: [TorBoxFile], query: Query) -> Outcome {
        var videoCount = 0
        var infectedVideos = 0
        var zippedVideos = 0
        var entries: [Entry] = []
        for (position, file) in files.enumerated() {
            guard isVideo(file) else { continue }
            videoCount += 1
            if file.infected { infectedVideos += 1; continue }
            if file.zipped { zippedVideos += 1; continue }
            guard let id = file.id else { continue }
            entries.append(Entry(file: file, id: id, position: position, size: file.size ?? 0,
                                 tag: episodeTag(for: file)))
        }

        if videoCount == 0 {
            let hasArchive = files.contains(where: { (file: TorBoxFile) -> Bool in return isArchive(file) })
            return hasArchive ? Outcome.archivesOnly : Outcome.noVideo
        }
        if entries.isEmpty {
            if infectedVideos > 0 { return Outcome.infectedOnly }
            if zippedVideos > 0 { return Outcome.archivesOnly }
            return Outcome.noVideo
        }

        // 1. File name hint.
        if let hint = query.filename?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            let matches = entries.filter { (entry: Entry) -> Bool in return nameMatches(hint, entry.file) }
            if !matches.isEmpty {
                let best = pick(matches, query: query, largestFirst: false)
                return Outcome.selected(best.file, .filenameHint)
            }
        }

        // 2. Episodes.
        if query.expectsEpisode {
            if let wanted = query.episode {
                let matches = entries.filter { (entry: Entry) -> Bool in
                    guard let tag = entry.tag else { return false }
                    return tag.contains(wanted)
                }
                if !matches.isEmpty {
                    let best = pick(matches, query: query, largestFirst: false)
                    return Outcome.selected(best.file, .episodeNumber)
                }
            }
            if entries.count == 1, entries[0].tag == nil {
                return Outcome.selected(entries[0].file, .onlyVideo)
            }
            return Outcome.noConfidentMatch(candidates(from: entries))
        }

        // 3. Movies.
        if entries.count == 1 {
            return Outcome.selected(entries[0].file, .onlyVideo)
        }
        let largest = pick(entries, query: query, largestFirst: true)
        return Outcome.selected(largest.file, .largestVideo)
    }

    static func candidates(from entries: [Entry]) -> [DebridFileCandidate] {
        let sorted = entries.sorted { (a: Entry, b: Entry) -> Bool in
            let left = a.file.name.lowercased()
            let right = b.file.name.lowercased()
            if left != right { return left < right }
            return a.id < b.id
        }
        return sorted.map { (entry: Entry) -> DebridFileCandidate in
            return DebridFileCandidate(id: entry.id, name: entry.file.displayName, path: entry.file.name,
                                       size: entry.file.size)
        }
    }

    private static func pick(_ entries: [Entry], query: Query, largestFirst: Bool) -> Entry {
        var best = entries[0]
        for entry in entries.dropFirst() {
            if isPreferred(entry, over: best, query: query, largestFirst: largestFirst) {
                best = entry
            }
        }
        return best
    }

    private static func isPreferred(_ a: Entry, over b: Entry, query: Query, largestFirst: Bool) -> Bool {
        if largestFirst && a.size != b.size { return a.size > b.size }
        let aSample = isSample(a.file)
        let bSample = isSample(b.file)
        if aSample != bSample { return !aSample }
        if let wanted = query.sizeHint, wanted > 0 {
            let aMatch = a.size == wanted
            let bMatch = b.size == wanted
            if aMatch != bMatch { return aMatch }
        }
        if let index = query.fileIndexHint {
            let aMatch = a.position == index
            let bMatch = b.position == index
            if aMatch != bMatch { return aMatch }
        }
        if a.size != b.size { return a.size > b.size }
        return a.position < b.position
    }

    // MARK: File kinds

    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "wmv", "flv", "webm", "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "ogv", "ogm",
        "divx", "rmvb", "3gp", "asf"
    ]

    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "iso"]

    static func fileExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        let ext = name[name.index(after: dot)...].lowercased()
        return ext.count <= 5 && !ext.contains("/") ? ext : ""
    }

    public static func isVideo(_ file: TorBoxFile) -> Bool {
        if let mime = file.mimetype?.lowercased(), mime.hasPrefix("video/") { return true }
        return videoExtensions.contains(fileExtension(of: file.displayName))
    }

    static func isArchive(_ file: TorBoxFile) -> Bool {
        return archiveExtensions.contains(fileExtension(of: file.displayName))
    }

    static func isSample(_ file: TorBoxFile) -> Bool {
        return tokens(of: file.name).contains("sample")
    }

    private static func tokens(of text: String) -> Set<String> {
        var result = Set<String>()
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                result.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { result.insert(current) }
        return result
    }

    // MARK: File name hint

    /// Torrentio's `sameTorboxFilename` comparison: lower case, `&` -> `and`, only letters and digits kept (Unicode aware),
    /// canonically composed first so that a decomposed "e" + U+0301 equals a precomposed "é".
    public static func normalizedName(_ text: String) -> String {
        let composed = text.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "&", with: "and")
        var scalars = String.UnicodeScalarView()
        for scalar in composed.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    static func nameMatches(_ hint: String, _ file: TorBoxFile) -> Bool {
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHint.isEmpty { return false }
        var names: [String] = [file.displayName, file.name]
        if let slash = file.name.lastIndex(of: "/") {
            names.append(String(file.name[file.name.index(after: slash)...]))
        }
        let composedHint = trimmedHint.precomposedStringWithCanonicalMapping
        for name in names {
            if name == trimmedHint { return true }
            if name.precomposedStringWithCanonicalMapping == composedHint { return true }
        }
        let normalizedHint = normalizedName(trimmedHint)
        if normalizedHint.isEmpty { return false }
        for name in names {
            if normalizedName(name) == normalizedHint { return true }
        }
        return false
    }

    // MARK: Season / episode parsing

    struct EpisodeTag: Equatable {
        let season: Int
        let first: Int
        let last: Int

        func contains(_ episode: DebridEpisode) -> Bool {
            return season == episode.season && episode.episode >= first && episode.episode <= last
        }
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals in this file; a failure here is a programming error caught by the unit tests.
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// S01E02, s01e02, S01.E02, S01 E02, S01E02E03 (a range), S01E02-E03.
    private static let seasonEpisodeRegex: NSRegularExpression = makeRegex(
        "(?<![A-Za-z0-9])S(\\d{1,2})[ ._-]?E(\\d{1,3})((?:[ ._-]?E\\d{1,3})*)(?![0-9])")

    /// 1x02 (never the 1920x1080 of a resolution).
    private static let crossRegex: NSRegularExpression = makeRegex(
        "(?<![A-Za-z0-9])(\\d{1,2})x(\\d{1,3})(?![A-Za-z0-9])")

    /// Season 1 Episode 2, Season.1.Episode.02, Stagione 2 Ep 05.
    private static let wordRegex: NSRegularExpression = makeRegex(
        "(?:season|stagione|saison|staffel)[ ._-]*(\\d{1,2})[ ._,-]*(?:episode|episodio|ep|e)[ ._-]*(\\d{1,3})(?![0-9])")

    /// A folder that names a season: "Season 1", "Stagione 02", "S03", "Show.Name.S02.1080p".
    private static let seasonFolderRegex: NSRegularExpression = makeRegex(
        "(?<![A-Za-z0-9])(?:season|stagione|saison|staffel|s)[ ._-]*(\\d{1,2})(?![A-Za-z0-9])")

    /// "E02", "Ep.03", "Episode 4", "Episodio 5" with no season.
    private static let episodeOnlyRegex: NSRegularExpression = makeRegex(
        "(?<![A-Za-z0-9])(?:episode|episodio|ep|e)[ ._-]*(\\d{1,3})(?![A-Za-z0-9])")

    /// "03 - Title.mkv", "03.mkv".
    private static let leadingNumberRegex: NSRegularExpression = makeRegex(
        "^(\\d{1,3})(?=[ ._-])")

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range)
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let nsRange = match.range(at: index)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return nil }
        return String(text[range])
    }

    private static func intGroup(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> Int? {
        guard let raw = group(match, index, in: text) else { return nil }
        return Int(raw)
    }

    private static func digitRuns(in text: String) -> [Int] {
        var runs: [Int] = []
        var current = ""
        for character in text {
            if character.isASCII && character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                if let value = Int(current) { runs.append(value) }
                current = ""
            }
        }
        if !current.isEmpty, let value = Int(current) { runs.append(value) }
        return runs
    }

    /// Season and episode written in one piece of text (a file or folder name).
    static func fullTag(in text: String) -> EpisodeTag? {
        if let match = firstMatch(seasonEpisodeRegex, in: text),
           let season = intGroup(match, 1, in: text), let episode = intGroup(match, 2, in: text) {
            var last = episode
            let tail = group(match, 3, in: text) ?? ""
            for value in digitRuns(in: tail) where value > last && value - episode <= 30 {
                last = value
            }
            return EpisodeTag(season: season, first: episode, last: last)
        }
        if let match = firstMatch(crossRegex, in: text),
           let season = intGroup(match, 1, in: text), let episode = intGroup(match, 2, in: text) {
            return EpisodeTag(season: season, first: episode, last: episode)
        }
        if let match = firstMatch(wordRegex, in: text),
           let season = intGroup(match, 1, in: text), let episode = intGroup(match, 2, in: text) {
            return EpisodeTag(season: season, first: episode, last: episode)
        }
        return nil
    }

    /// Season named by a folder of the path. A folder naming several seasons ("S01-S03") says nothing about one file.
    static func seasonFromFolders(_ folders: [String]) -> Int? {
        for folder in folders.reversed() {
            let range = NSRange(folder.startIndex..., in: folder)
            let matches = seasonFolderRegex.matches(in: folder, options: [], range: range)
            if matches.count == 1, let season = intGroup(matches[0], 1, in: folder) {
                return season
            }
        }
        return nil
    }

    static func episodeOnly(in fileName: String) -> Int? {
        if let match = firstMatch(episodeOnlyRegex, in: fileName), let value = intGroup(match, 1, in: fileName) {
            return value
        }
        if let match = firstMatch(leadingNumberRegex, in: fileName), let value = intGroup(match, 1, in: fileName) {
            return value
        }
        return nil
    }

    static func folderComponents(of path: String) -> [String] {
        var parts: [String] = path.split(separator: "/", omittingEmptySubsequences: true).map { (part: Substring) -> String in
            return String(part)
        }
        if !parts.isEmpty { parts.removeLast() }
        return parts
    }

    static func episodeTag(for file: TorBoxFile) -> EpisodeTag? {
        let fileName = file.displayName
        if let tag = fullTag(in: fileName) { return tag }
        let folders = folderComponents(of: file.name)
        for folder in folders.reversed() {
            if let tag = fullTag(in: folder) { return tag }
        }
        if let season = seasonFromFolders(folders), let episode = episodeOnly(in: fileName) {
            return EpisodeTag(season: season, first: episode, last: episode)
        }
        return nil
    }
}
