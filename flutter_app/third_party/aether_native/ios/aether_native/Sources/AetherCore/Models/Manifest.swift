import Foundation

/// Well known Stremio content types. Addons may declare others (e.g. `anime`, `other`),
/// so types are kept as plain strings across the engine.
public enum ContentType {
    public static let movie = "movie"
    public static let series = "series"
    public static let channel = "channel"
    public static let tv = "tv"
    public static let anime = "anime"
    public static let other = "other"

    /// Types whose `videos` represent playable episodes/uploads.
    public static func hasEpisodes(_ type: String) -> Bool {
        return type == series || type == anime || type == channel
    }

    public static func isLive(_ type: String) -> Bool {
        return type == tv
    }
}

/// `name=value` pair appended to a resource path (`/catalog/movie/top/search=x&skip=100.json`).
public struct ExtraValue: Codable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// `{resource}/{type}/{id}` plus optional extra values. Mirrors `ResourcePath` in stremio-core.
public struct ResourcePath: Codable, Hashable, Sendable {
    public var resource: String
    public var type: String
    public var id: String
    public var extra: [ExtraValue]

    public init(resource: String, type: String, id: String, extra: [ExtraValue] = []) {
        self.resource = resource
        self.type = type
        self.id = id
        self.extra = extra
    }

    public func extraValue(_ name: String) -> String? {
        return extra.first(where: { $0.name == name })?.value
    }
}

public enum ResourceName {
    public static let catalog = "catalog"
    public static let meta = "meta"
    public static let stream = "stream"
    public static let subtitles = "subtitles"
    public static let addonCatalog = "addon_catalog"
}

/// An entry of `manifest.resources`: either a plain string or `{name, types?, idPrefixes?}`.
public struct ManifestResource: Codable, Hashable, Sendable {
    public var name: String
    public var types: [String]?
    public var idPrefixes: [String]?

    public init(name: String, types: [String]? = nil, idPrefixes: [String]? = nil) {
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
    }

    private enum CodingKeys: String, CodingKey {
        case name, types, idPrefixes
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let string = try? single.decode(String.self) {
            self.name = string
            self.types = nil
            self.idPrefixes = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        let types = container.stringList(.types)
        self.types = container.contains(.types) ? types : nil
        let prefixes = container.stringList(.idPrefixes)
        self.idPrefixes = container.contains(.idPrefixes) ? prefixes : nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(types, forKey: .types)
        try container.encodeIfPresent(idPrefixes, forKey: .idPrefixes)
    }
}

/// `catalogs[].extra[]`
public struct ExtraProperty: Codable, Hashable, Sendable {
    public var name: String
    public var isRequired: Bool
    public var options: [String]
    public var optionsLimit: Int

    public init(name: String, isRequired: Bool = false, options: [String] = [], optionsLimit: Int = 1) {
        self.name = name
        self.isRequired = isRequired
        self.options = options
        self.optionsLimit = optionsLimit
    }

    private enum CodingKeys: String, CodingKey {
        case name, isRequired, options, optionsLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.isRequired = container.flexBool(.isRequired) ?? false
        self.options = container.stringList(.options)
        let limit = container.flexInt(.optionsLimit) ?? 1
        self.optionsLimit = limit < 0 ? 1 : limit
    }
}

public struct ManifestCatalog: Codable, Hashable, Sendable {
    public var type: String
    public var id: String
    public var name: String
    public var extra: [ExtraProperty]

    public init(type: String, id: String, name: String? = nil, extra: [ExtraProperty] = []) {
        self.type = type
        self.id = id
        self.name = name ?? id
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, name, extra, extraSupported, extraRequired
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.id = try container.decode(String.self, forKey: .id)
        let declaredName = container.flexString(.name)
        if let declaredName = declaredName, !declaredName.trimmingCharacters(in: .whitespaces).isEmpty {
            self.name = declaredName
        } else {
            self.name = self.id
        }
        var extras = container.lossyArray(ExtraProperty.self, forKey: .extra)
        if extras.isEmpty {
            // Legacy "short" format: extraSupported: ["search","skip"], extraRequired: ["search"].
            let supported = container.stringList(.extraSupported)
            let required = Set(container.stringList(.extraRequired))
            var names = supported
            for name in required where !names.contains(name) {
                names.append(name)
            }
            extras = names.map { ExtraProperty(name: $0, isRequired: required.contains($0)) }
        }
        self.extra = extras
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(extra, forKey: .extra)
    }

    /// Stable identity inside one addon.
    public var key: String { return "\(type)/\(id)" }

    public func extraProperty(_ name: String) -> ExtraProperty? {
        return extra.first(where: { $0.name == name })
    }

    public var supportsSearch: Bool { return extraProperty("search") != nil }
    public var supportsSkip: Bool { return extraProperty("skip") != nil }
    public var genreOptions: [String] { return extraProperty("genre")?.options ?? [] }

    /// Required extras other than `skip`; a catalog with such extras cannot be shown as a plain feed.
    public var requiredExtraNames: [String] {
        return extra.filter { $0.isRequired }.map { $0.name }
    }

    /// True if the catalog can be listed without the user supplying anything
    /// (no required extra, and not a pure-search or EPG-date catalog).
    public var isPlainFeed: Bool {
        return requiredExtraNames.isEmpty
    }

    /// Port of `ManifestCatalog::is_extra_supported` (stremio-core): every given extra must be declared,
    /// and every `isRequired` extra must be given.
    public func isExtraSupported(_ given: [ExtraValue]) -> Bool {
        let allDeclared = given.allSatisfy { value in
            extra.contains(where: { $0.name == value.name })
        }
        let requiredSatisfied = extra.filter { $0.isRequired }.allSatisfy { property in
            given.contains(where: { $0.name == property.name })
        }
        return allDeclared && requiredSatisfied
    }
}

public struct ManifestBehaviorHints: Codable, Hashable, Sendable {
    public var adult: Bool
    public var p2p: Bool
    public var configurable: Bool
    public var configurationRequired: Bool
    public var epgProvider: Bool

    public init(adult: Bool = false, p2p: Bool = false, configurable: Bool = false,
                configurationRequired: Bool = false, epgProvider: Bool = false) {
        self.adult = adult
        self.p2p = p2p
        self.configurable = configurable
        self.configurationRequired = configurationRequired
        self.epgProvider = epgProvider
    }

    private enum CodingKeys: String, CodingKey {
        case adult, p2p, configurable, configurationRequired, epgProvider
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.adult = container.flexBool(.adult) ?? false
        self.p2p = container.flexBool(.p2p) ?? false
        self.configurable = container.flexBool(.configurable) ?? false
        self.configurationRequired = container.flexBool(.configurationRequired) ?? false
        self.epgProvider = container.flexBool(.epgProvider) ?? false
    }
}

/// `manifest.config[]` entry (user data form generated by the addon landing page).
public struct ManifestConfigItem: Codable, Hashable, Sendable {
    public var key: String
    public var type: String
    public var title: String?
    public var defaultValue: String?
    public var options: [String]
    public var isRequired: Bool

    private enum CodingKeys: String, CodingKey {
        case key, type, title, options
        case isRequired = "required"
        case defaultValue = "default"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)
        self.type = container.flexString(.type) ?? "text"
        self.title = container.flexString(.title)
        self.defaultValue = container.flexString(.defaultValue)
        self.options = container.stringList(.options)
        self.isRequired = container.flexBool(.isRequired) ?? false
    }
}

/// A Stremio addon manifest (`/manifest.json`).
public struct AddonManifest: Codable, Hashable, Sendable {
    public var id: String
    public var version: String
    public var name: String
    public var description: String?
    public var logo: String?
    public var background: String?
    public var contactEmail: String?
    public var types: [String]
    public var resources: [ManifestResource]
    public var idPrefixes: [String]?
    public var catalogs: [ManifestCatalog]
    public var addonCatalogs: [ManifestCatalog]
    public var behaviorHints: ManifestBehaviorHints
    public var config: [ManifestConfigItem]

    public init(id: String, version: String, name: String, description: String? = nil,
                logo: String? = nil, background: String? = nil, contactEmail: String? = nil,
                types: [String] = [], resources: [ManifestResource] = [], idPrefixes: [String]? = nil,
                catalogs: [ManifestCatalog] = [], addonCatalogs: [ManifestCatalog] = [],
                behaviorHints: ManifestBehaviorHints = ManifestBehaviorHints(),
                config: [ManifestConfigItem] = []) {
        self.id = id
        self.version = version
        self.name = name
        self.description = description
        self.logo = logo
        self.background = background
        self.contactEmail = contactEmail
        self.types = types
        self.resources = resources
        self.idPrefixes = idPrefixes
        self.catalogs = catalogs
        self.addonCatalogs = addonCatalogs
        self.behaviorHints = behaviorHints
        self.config = config
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, name, description, logo, background, contactEmail
        case types, resources, idPrefixes, catalogs, addonCatalogs, behaviorHints, config
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexString(.id), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "id"))
        }
        guard let name = container.flexString(.name), !name.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.name,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "name"))
        }
        guard let version = container.flexString(.version), !version.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.version,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "version"))
        }
        self.id = id
        self.name = name
        self.version = version
        self.description = container.flexString(.description)
        self.logo = container.flexString(.logo)
        self.background = container.flexString(.background)
        self.contactEmail = container.flexString(.contactEmail)
        self.types = container.stringList(.types)
        self.resources = container.lossyArray(ManifestResource.self, forKey: .resources)
        self.idPrefixes = container.contains(.idPrefixes) ? container.stringList(.idPrefixes) : nil
        self.catalogs = container.lossyArray(ManifestCatalog.self, forKey: .catalogs)
        self.addonCatalogs = container.lossyArray(ManifestCatalog.self, forKey: .addonCatalogs)
        self.behaviorHints = container.lenient(ManifestBehaviorHints.self, forKey: .behaviorHints)
            ?? ManifestBehaviorHints()
        self.config = container.lossyArray(ManifestConfigItem.self, forKey: .config)
    }

    // MARK: Capability queries

    public func resource(named name: String) -> ManifestResource? {
        return resources.first(where: { $0.name == name })
    }

    public func declares(_ resourceName: String) -> Bool {
        if resourceName == ResourceName.catalog { return !catalogs.isEmpty }
        if resourceName == ResourceName.addonCatalog { return !addonCatalogs.isEmpty }
        return resource(named: resourceName) != nil
    }

    /// Port of `Manifest::is_resource_supported` (stremio-core) with the lenient fallbacks
    /// described in docs/01-RESEARCH-MATRIX.md: a full resource without `types` inherits the manifest `types`.
    public func supports(_ path: ResourcePath) -> Bool {
        switch path.resource {
        case ResourceName.catalog:
            return catalogs.contains(where: {
                $0.type == path.type && $0.id == path.id && $0.isExtraSupported(path.extra)
            })
        case ResourceName.addonCatalog:
            return addonCatalogs.contains(where: {
                $0.type == path.type && $0.id == path.id && $0.isExtraSupported(path.extra)
            })
        default:
            guard let resource = resource(named: path.resource) else { return false }
            let effectiveTypes: [String]
            let effectivePrefixes: [String]?
            if let ownTypes = resource.types, !ownTypes.isEmpty {
                effectiveTypes = ownTypes
                effectivePrefixes = resource.idPrefixes
            } else if resource.types == nil && resource.idPrefixes == nil {
                // Short notation: inherit both from the manifest.
                effectiveTypes = types
                effectivePrefixes = idPrefixes
            } else {
                effectiveTypes = types
                effectivePrefixes = resource.idPrefixes
            }
            guard effectiveTypes.contains(path.type) else { return false }
            guard let prefixes = effectivePrefixes, !prefixes.isEmpty else { return true }
            return prefixes.contains(where: { path.id.hasPrefix($0) })
        }
    }

    /// Short human-readable list of what this addon provides.
    public var capabilitySummary: [String] {
        var parts: [String] = []
        if !catalogs.isEmpty { parts.append(ResourceName.catalog) }
        for resource in resources where resource.name != ResourceName.catalog {
            if !parts.contains(resource.name) { parts.append(resource.name) }
        }
        if !addonCatalogs.isEmpty && !parts.contains(ResourceName.addonCatalog) {
            parts.append(ResourceName.addonCatalog)
        }
        return parts
    }
}

/// Reasons a manifest is refused. Messages are shown to the user (Italian).
public enum ManifestValidationError: Error, Equatable, Sendable {
    case missingField(String)
    case noResources
    case invalidCatalog(String)
    case unsupportedTransport(String)
    case tooManyCatalogs(Int)

    public var message: String {
        switch self {
        case .missingField(let field):
            return "Manifest non valido: campo obbligatorio «\(field)» mancante."
        case .noResources:
            return "Manifest non valido: l'addon non dichiara nessuna risorsa."
        case .invalidCatalog(let detail):
            return "Manifest non valido: catalogo non corretto (\(detail))."
        case .unsupportedTransport(let detail):
            return "Trasporto non supportato: \(detail)."
        case .tooManyCatalogs(let count):
            return "Manifest rifiutato: \(count) cataloghi superano il limite consentito."
        }
    }
}

public enum ManifestValidator {
    public static let maxCatalogs = 500

    /// Structural validation beyond what the lenient decoder guarantees.
    public static func validate(_ manifest: AddonManifest) throws {
        if manifest.id.trimmingCharacters(in: .whitespaces).isEmpty { throw ManifestValidationError.missingField("id") }
        if manifest.name.trimmingCharacters(in: .whitespaces).isEmpty { throw ManifestValidationError.missingField("name") }
        if manifest.version.trimmingCharacters(in: .whitespaces).isEmpty { throw ManifestValidationError.missingField("version") }
        if manifest.resources.isEmpty && manifest.catalogs.isEmpty {
            throw ManifestValidationError.noResources
        }
        if manifest.catalogs.count > maxCatalogs {
            throw ManifestValidationError.tooManyCatalogs(manifest.catalogs.count)
        }
        for catalog in manifest.catalogs {
            if catalog.type.isEmpty || catalog.id.isEmpty {
                throw ManifestValidationError.invalidCatalog("type/id vuoti")
            }
        }
        for resource in manifest.resources where resource.name.isEmpty {
            throw ManifestValidationError.missingField("resources.name")
        }
    }
}
