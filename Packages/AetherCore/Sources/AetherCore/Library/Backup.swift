import Foundation

/// Deterministic three-way-free merge of two library states (device A + backup/other device B).
///
/// * Per record the most recently modified side wins (last-writer-wins); ties keep `local`.
/// * Removals are tombstones (`LibraryEntry.isRemoved`) and win like any other newer write, so a deletion on one
///   side is not undone by an older copy on the other. Tombstones older than a year are pruned.
/// * Watch progress merges per video; a completed flag is never lost to an equal-time older position.
/// * Search history is the union, newest first, capped.
public enum LibraryMerge {
    public static let tombstoneRetention: TimeInterval = 365 * 86400

    public static func merge(local: LibraryState, remote: LibraryState, now: Date,
                             maxSearchHistory: Int = 30) -> LibraryState {
        var result = LibraryState()

        let entryIDs = Set(local.entries.keys).union(remote.entries.keys)
        for id in entryIDs {
            let l = local.entries[id]
            let r = remote.entries[id]
            let chosen: LibraryEntry?
            switch (l, r) {
            case (let l?, let r?):
                chosen = r.modifiedAt > l.modifiedAt ? r : l
            case (let l?, nil):
                chosen = l
            case (nil, let r?):
                chosen = r
            case (nil, nil):
                chosen = nil
            }
            guard let entry = chosen else { continue }
            if entry.isRemoved && now.timeIntervalSince(entry.modifiedAt) > tombstoneRetention { continue }
            result.entries[id] = entry
        }

        let progressIDs = Set(local.progress.keys).union(remote.progress.keys)
        for id in progressIDs {
            let l = local.progress[id]
            let r = remote.progress[id]
            switch (l, r) {
            case (let l?, let r?):
                var winner = r.updatedAt > l.updatedAt ? r : l
                let loser = r.updatedAt > l.updatedAt ? l : r
                if loser.isCompleted && !winner.isCompleted && winner.updatedAt == loser.updatedAt {
                    winner.isCompleted = true
                }
                if winner.duration == 0 && loser.duration > 0 { winner.duration = loser.duration }
                result.progress[id] = winner
            case (let l?, nil):
                result.progress[id] = l
            case (nil, let r?):
                result.progress[id] = r
            case (nil, nil):
                break
            }
        }

        var latestQuery: [String: SearchHistoryItem] = [:]
        for item in local.searchHistory + remote.searchHistory {
            if let existing = latestQuery[item.id], existing.date >= item.date { continue }
            latestQuery[item.id] = item
        }
        result.searchHistory = Array(latestQuery.values.sorted { $0.date > $1.date }.prefix(maxSearchHistory))
        return result
    }
}

/// An addon as stored in a backup. The secret URL is only included when the user explicitly opts in.
public struct BackupAddon: Codable, Sendable {
    public var addon: InstalledAddon
    public var url: String?

    public init(addon: InstalledAddon, url: String?) {
        self.addon = addon
        self.url = url
    }
}

/// Self-describing, versioned backup document (`.aetherbackup`, plain JSON).
public struct AetherBackup: Codable, Sendable {
    public static let currentFormat = 1
    public static let marker = "app.aether.backup"

    public var marker: String
    public var formatVersion: Int
    public var createdAt: Date
    public var appVersion: String
    public var library: LibraryState
    public var settings: AppSettings?
    public var addons: [BackupAddon]
    /// True if addon URLs (which may contain API keys) are included.
    public var includesAddonURLs: Bool

    public init(createdAt: Date = Date(), appVersion: String, library: LibraryState, settings: AppSettings?,
                addons: [BackupAddon], includesAddonURLs: Bool) {
        self.marker = AetherBackup.marker
        self.formatVersion = AetherBackup.currentFormat
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.library = library
        self.settings = settings
        self.addons = addons
        self.includesAddonURLs = includesAddonURLs
    }
}

public enum BackupError: Error, Equatable, Sendable {
    case notABackup
    case unsupportedVersion(Int)
    case unreadable

    public var message: String {
        switch self {
        case .notABackup: return "Il file non è un backup di Aether."
        case .unsupportedVersion(let version): return "Backup creato da una versione più recente (formato \(version))."
        case .unreadable: return "Il file di backup è danneggiato."
        }
    }
}

public enum BackupCodec {
    public static func encode(_ backup: AetherBackup) throws -> Data {
        return try JSONEncoder.aether(pretty: true).encode(backup)
    }

    public static func decode(_ data: Data) throws -> AetherBackup {
        // Peek at the header first to give precise errors.
        struct Header: Decodable { var marker: String?; var formatVersion: Int? }
        guard let header = try? JSONDecoder.aether().decode(Header.self, from: data) else {
            throw BackupError.unreadable
        }
        guard header.marker == AetherBackup.marker else { throw BackupError.notABackup }
        if let version = header.formatVersion, version > AetherBackup.currentFormat {
            throw BackupError.unsupportedVersion(version)
        }
        do {
            return try JSONDecoder.aether().decode(AetherBackup.self, from: data)
        } catch {
            throw BackupError.unreadable
        }
    }
}
