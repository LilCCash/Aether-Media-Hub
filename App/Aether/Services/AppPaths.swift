import Foundation

/// Every on-disk location the app uses, in one place.
struct AppPaths {
    let root: URL

    var addonsFile: URL { root.appendingPathComponent("addons.json") }
    var libraryFile: URL { root.appendingPathComponent("library.json") }
    var downloadsFile: URL { root.appendingPathComponent("downloads.json") }
    var downloadsDirectory: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    var subtitlesDirectory: URL { root.appendingPathComponent("Subtitles", isDirectory: true) }
    var responseCacheDirectory: URL { cachesRoot.appendingPathComponent("responses", isDirectory: true) }
    var imageCacheDirectory: URL { cachesRoot.appendingPathComponent("images", isDirectory: true) }
    let cachesRoot: URL

    static func standard() -> AppPaths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aether", isDirectory: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Aether", isDirectory: true)
        let paths = AppPaths(root: support, cachesRoot: caches)
        paths.prepare()
        return paths
    }

    /// Isolated, empty storage used by UI tests so runs never see each other's state.
    static func ephemeral() -> AppPaths {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("aether-uitest-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: base.appendingPathComponent("support", isDirectory: true),
                             cachesRoot: base.appendingPathComponent("caches", isDirectory: true))
        paths.prepare()
        return paths
    }

    private func prepare() {
        let fm = FileManager.default
        for url in [root, downloadsDirectory, subtitlesDirectory, responseCacheDirectory, imageCacheDirectory] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // Downloads are re-creatable and large: keep them out of iCloud/iTunes backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var downloads = downloadsDirectory
        try? downloads.setResourceValues(values)
    }

    /// Free space available for important usage, in bytes.
    static func availableCapacity() -> Int64 {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        return 0
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
