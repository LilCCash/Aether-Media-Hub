import Foundation

// Tolerant Decodable models for the TorBox API (https://api.torbox.app/v1/api).
//
// The contract is only partly verified (docs/research/torbox-api.md section 8, docs/research/api-probe-2026-10-20.md):
// every field is optional, numbers may arrive as strings, `data` may be a list, an object, a string or null, and error
// bodies may lack `success`/`error` altogether (`{"detail":"Not authenticated"}`). Decoding therefore never throws on a
// wrong field type: a missing or odd value becomes nil / empty. Only the structural minimum (a torrent needs an id, the
// response must be a JSON object) is enforced.
//
// The user's e-mail address is present in `user/me` but is deliberately NOT modelled, so it can never be stored or logged.

// MARK: - Helpers

struct TorBoxDynamicKey: CodingKey {
    var stringValue: String

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    var intValue: Int? { return nil }

    init?(intValue: Int) {
        return nil
    }
}

/// Consumes any JSON value; used to step over elements that failed to decode (same trick as `LossyArray`).
struct TorBoxSkip: Decodable {
    init(from decoder: Decoder) throws {}
}

/// A number that may arrive as a JSON number or a numeric string.
struct TorBoxFlexDouble: Decodable {
    var value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let double = try? container.decode(Double.self) {
            value = double.isFinite ? double : nil
        } else if let string = try? container.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            if let double = Double(trimmed), double.isFinite {
                value = double
            } else {
                value = nil
            }
        } else {
            value = nil
        }
    }
}

extension KeyedDecodingContainer {
    func tbDouble(_ key: Key) -> Double? {
        let wrapped = try? decodeIfPresent(TorBoxFlexDouble.self, forKey: key)
        return wrapped?.value
    }

    func tbInt64(_ key: Key) -> Int64? {
        guard let value = tbDouble(key), abs(value) < 9e15 else { return nil }
        return Int64(value)
    }
}

/// `detail` is a string for TorBox errors but a list of `{loc,msg,type}` objects for FastAPI validation errors.
struct TorBoxDetailText: Decodable {
    var text: String?

    private struct Item: Decodable {
        var message: String?

        private enum CodingKeys: String, CodingKey { case msg, message }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.message = container.flexString(.msg) ?? container.flexString(.message)
        }
    }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            text = nil
        } else if let string = try? single.decode(String.self) {
            text = string
        } else if let item = try? single.decode(Item.self) {
            // A single object (keyed). Arrays fail here and fall through to the lossy list below.
            text = item.message
        } else if let items = try? single.decode(LossyArray<Item>.self) {
            let parts: [String] = items.elements.compactMap { (entry: Item) -> String? in return entry.message }
            text = parts.isEmpty ? nil : parts.joined(separator: "; ")
        } else {
            text = nil
        }
    }
}

// MARK: - Envelope

/// `{"success": bool, "error": null | "CODE", "detail": "text", "data": ...}`.
struct TorBoxEnvelope<Payload: Decodable>: Decodable {
    var success: Bool?
    var error: String?
    var detail: String?
    var data: Payload?
    /// `data` was present, not null, but could not be read as `Payload`.
    var dataUnreadable: Bool

    private enum CodingKeys: String, CodingKey { case success, error, detail, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = container.flexBool(.success)
        self.error = container.flexString(.error)
        let detailText = try? container.decodeIfPresent(TorBoxDetailText.self, forKey: .detail)
        self.detail = detailText?.text
        let isNull = (try? container.decodeNil(forKey: .data)) ?? true
        if isNull {
            self.data = nil
            self.dataUnreadable = false
        } else {
            let decoded = try? container.decode(Payload.self, forKey: .data)
            self.data = decoded
            self.dataUnreadable = (decoded == nil)
        }
    }
}

// MARK: - user/me

public struct TorBoxUser: Equatable, Sendable, Decodable {
    /// 0 Free, 1 Essential, 2 Pro, 3 Standard (docstring of the official SDK; not verified against the live API).
    public var plan: Int?
    public var isSubscribed: Bool?
    public var premiumExpiresAt: Date?
    public var cooldownUntil: Date?

    public init(plan: Int? = nil, isSubscribed: Bool? = nil, premiumExpiresAt: Date? = nil, cooldownUntil: Date? = nil) {
        self.plan = plan
        self.isSubscribed = isSubscribed
        self.premiumExpiresAt = premiumExpiresAt
        self.cooldownUntil = cooldownUntil
    }

    private enum CodingKeys: String, CodingKey {
        case plan
        case isSubscribed = "is_subscribed"
        case premiumExpiresAt = "premium_expires_at"
        case cooldownUntil = "cooldown_until"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.plan = container.flexInt(.plan)
        self.isSubscribed = container.flexBool(.isSubscribed)
        self.premiumExpiresAt = AddonDate.parse(container.flexString(.premiumExpiresAt))
        self.cooldownUntil = AddonDate.parse(container.flexString(.cooldownUntil))
    }

    public var planName: String {
        guard let plan = plan else { return "Sconosciuto" }
        switch plan {
        case 0: return "Free"
        case 1: return "Essential"
        case 2: return "Pro"
        case 3: return "Standard"
        default: return "Piano \(plan)"
        }
    }
}

// MARK: - checkcached

public struct TorBoxCachedFile: Equatable, Sendable, Decodable {
    /// Full path including the root folder.
    public var name: String
    public var size: Int64?

    public init(name: String, size: Int64? = nil) {
        self.name = name
        self.size = size
    }

    private enum CodingKeys: String, CodingKey { case name, size }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = container.flexString(.name) ?? ""
        self.size = container.tbInt64(.size)
    }
}

public struct TorBoxCachedItem: Equatable, Sendable, Decodable {
    public var name: String?
    public var size: Int64?
    public var hash: String?
    /// Only present with `list_files=true`; ids are NOT included (they come from `mylist`).
    public var files: [TorBoxCachedFile]

    public init(name: String? = nil, size: Int64? = nil, hash: String? = nil, files: [TorBoxCachedFile] = []) {
        self.name = name
        self.size = size
        self.hash = hash
        self.files = files
    }

    private enum CodingKeys: String, CodingKey { case name, size, hash, files }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = container.flexString(.name)
        self.size = container.tbInt64(.size)
        self.hash = container.flexString(.hash)
        self.files = container.lossyArray(TorBoxCachedFile.self, forKey: .files)
    }
}

/// `data` of `checkcached`: `format=list` gives an array of items, `format=object` an object keyed by hash (only cached
/// hashes appear). Null, `[]`, `{}` and `false` all mean "nothing cached".
struct TorBoxCachedPayload: Decodable {
    var items: [TorBoxCachedItem]

    init(from decoder: Decoder) throws {
        var found: [TorBoxCachedItem] = []
        if var unkeyed = try? decoder.unkeyedContainer() {
            while !unkeyed.isAtEnd {
                if let item = try? unkeyed.decode(TorBoxCachedItem.self) {
                    found.append(item)
                } else {
                    _ = try? unkeyed.decode(TorBoxSkip.self)
                }
            }
        } else if let keyed = try? decoder.container(keyedBy: TorBoxDynamicKey.self) {
            if let hashKey = TorBoxDynamicKey(stringValue: "hash"), keyed.contains(hashKey),
               let single = try? TorBoxCachedItem(from: decoder) {
                // A single item instead of a list.
                found.append(single)
            } else {
                for key in keyed.allKeys {
                    if DebridHash.normalize(key.stringValue) == nil { continue }
                    if (try? keyed.decodeNil(forKey: key)) == true { continue }
                    if var item = try? keyed.decode(TorBoxCachedItem.self, forKey: key) {
                        if item.hash == nil { item.hash = key.stringValue }
                        found.append(item)
                    } else if let flag = try? keyed.decode(Bool.self, forKey: key) {
                        if flag { found.append(TorBoxCachedItem(hash: key.stringValue)) }
                    } else {
                        found.append(TorBoxCachedItem(hash: key.stringValue))
                    }
                }
            }
        }
        self.items = found
    }
}

// MARK: - mylist

public struct TorBoxFile: Hashable, Sendable, Decodable {
    public var id: Int?
    /// Full path including the root folder.
    public var name: String
    public var shortName: String?
    public var size: Int64?
    public var mimetype: String?
    public var zipped: Bool
    public var infected: Bool

    public init(id: Int?, name: String, shortName: String? = nil, size: Int64? = nil, mimetype: String? = nil,
                zipped: Bool = false, infected: Bool = false) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.size = size
        self.mimetype = mimetype
        self.zipped = zipped
        self.infected = infected
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, size, mimetype, zipped, infected
        case shortName = "short_name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.flexInt(.id)
        let short = container.flexString(.shortName)
        self.shortName = short
        self.name = container.flexString(.name) ?? short ?? ""
        self.size = container.tbInt64(.size)
        self.mimetype = container.flexString(.mimetype)
        self.zipped = container.flexBool(.zipped) ?? false
        self.infected = container.flexBool(.infected) ?? false
    }

    /// File name without folders: `short_name` when present, otherwise the last path component.
    public var displayName: String {
        if let short = shortName, !short.isEmpty { return short }
        if let slash = name.lastIndex(of: "/") {
            return String(name[name.index(after: slash)...])
        }
        return name
    }
}

public struct TorBoxTorrent: Equatable, Sendable, Decodable {
    public var id: Int
    public var hash: String?
    public var name: String?
    public var size: Int64?
    /// Scale not verified (probably 0...1). Use `DebridResolver`'s normalised fraction for display.
    public var progress: Double?
    public var downloadState: String?
    /// Unit not verified (probably bytes per second).
    public var downloadSpeed: Int64?
    /// Unit not verified (probably seconds).
    public var eta: Int?
    public var downloadFinished: Bool?
    public var downloadPresent: Bool?
    /// Only seen in newer clients; absent from the 2025 SDK.
    public var cached: Bool?
    public var active: Bool?
    public var files: [TorBoxFile]

    public init(id: Int, hash: String? = nil, name: String? = nil, size: Int64? = nil, progress: Double? = nil,
                downloadState: String? = nil, downloadSpeed: Int64? = nil, eta: Int? = nil,
                downloadFinished: Bool? = nil, downloadPresent: Bool? = nil, cached: Bool? = nil, active: Bool? = nil,
                files: [TorBoxFile] = []) {
        self.id = id
        self.hash = hash
        self.name = name
        self.size = size
        self.progress = progress
        self.downloadState = downloadState
        self.downloadSpeed = downloadSpeed
        self.eta = eta
        self.downloadFinished = downloadFinished
        self.downloadPresent = downloadPresent
        self.cached = cached
        self.active = active
        self.files = files
    }

    private enum CodingKeys: String, CodingKey {
        case id, hash, name, size, progress, eta, cached, active, files
        case downloadState = "download_state"
        case downloadSpeed = "download_speed"
        case downloadFinished = "download_finished"
        case downloadPresent = "download_present"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexInt(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "torrent id"))
        }
        self.id = id
        self.hash = container.flexString(.hash)
        self.name = container.flexString(.name)
        self.size = container.tbInt64(.size)
        self.progress = container.tbDouble(.progress)
        self.downloadState = container.flexString(.downloadState)
        self.downloadSpeed = container.tbInt64(.downloadSpeed)
        if let seconds = container.tbDouble(.eta), seconds >= 0, seconds < 1e9 {
            self.eta = Int(seconds)
        } else {
            self.eta = nil
        }
        self.downloadFinished = container.flexBool(.downloadFinished)
        self.downloadPresent = container.flexBool(.downloadPresent)
        self.cached = container.flexBool(.cached)
        self.active = container.flexBool(.active)
        self.files = container.lossyArray(TorBoxFile.self, forKey: .files)
    }

    /// Ready to play: the files are present on TorBox's servers and the download is finished (the rule stremthru and
    /// MediaFusion use). When `download_finished` is missing, a progress of 100 % is accepted as the second signal.
    public var isReady: Bool {
        guard downloadPresent == true else { return false }
        if let finished = downloadFinished { return finished }
        return (progress ?? 0) >= 1
    }
}

/// `data` of `mylist`: a list, or a single object when `id` was given. Null and anything else give an empty list.
struct TorBoxTorrentPayload: Decodable {
    var torrents: [TorBoxTorrent]

    init(from decoder: Decoder) throws {
        var found: [TorBoxTorrent] = []
        if var unkeyed = try? decoder.unkeyedContainer() {
            while !unkeyed.isAtEnd {
                if let torrent = try? unkeyed.decode(TorBoxTorrent.self) {
                    found.append(torrent)
                } else {
                    _ = try? unkeyed.decode(TorBoxSkip.self)
                }
            }
        } else if let single = try? TorBoxTorrent(from: decoder) {
            found.append(single)
        }
        self.torrents = found
    }
}

// MARK: - createtorrent

public struct TorBoxCreateResult: Equatable, Sendable, Decodable {
    /// Present when the torrent was added to the account.
    public var torrentID: Int?
    /// Present instead of `torrentID` when TorBox put the request in its queue.
    public var queuedID: Int?
    public var hash: String?
    /// The response `detail` said TorBox used its cached copy ("Found Cached Torrent. Using Cached Torrent."). Set by the client.
    public var usedCachedCopy: Bool

    public init(torrentID: Int? = nil, queuedID: Int? = nil, hash: String? = nil, usedCachedCopy: Bool = false) {
        self.torrentID = torrentID
        self.queuedID = queuedID
        self.hash = hash
        self.usedCachedCopy = usedCachedCopy
    }

    private enum CodingKeys: String, CodingKey {
        case hash
        case torrentID = "torrent_id"
        case queuedID = "queued_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.torrentID = container.flexInt(.torrentID)
        self.queuedID = container.flexInt(.queuedID)
        self.hash = container.flexString(.hash)
        self.usedCachedCopy = false
    }
}

// MARK: - requestdl

/// `data` of `requestdl`: the CDN URL as a string (an object with `url` / `link` is accepted too).
struct TorBoxLinkPayload: Decodable {
    var url: String?

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let string = try? single.decode(String.self) {
            self.url = string
        } else if let keyed = try? decoder.container(keyedBy: TorBoxDynamicKey.self) {
            var found: String?
            for name in ["url", "link", "download"] {
                guard let key = TorBoxDynamicKey(stringValue: name) else { continue }
                if let value = try? keyed.decode(String.self, forKey: key) {
                    found = value
                    break
                }
            }
            self.url = found
        } else {
            self.url = nil
        }
    }
}
