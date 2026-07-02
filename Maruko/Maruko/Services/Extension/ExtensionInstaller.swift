import Foundation

nonisolated enum ExtensionInstallerError: LocalizedError {
    case bundledExtensionMissing

    var errorDescription: String? {
        switch self {
        case .bundledExtensionMissing:
            return "The bundled Chrome extension is missing from the app. Reinstall Maruko."
        }
    }
}

/// Exports the Chrome extension bundled in Maruko.app to a plain folder
/// Chrome can load unpacked. Chrome re-reads unpacked extension files on
/// load/reload, so re-exporting in place is safe while Chrome runs.
nonisolated struct ExtensionInstaller {
    enum ExportState: Equatable {
        case notExported
        case upToDate(URL)
        /// The bundled copy is newer than the export.
        case outdated(exportedVersion: String, bundledVersion: String, url: URL)
    }

    static let exportFolderName = "ChromeExtension"

    private let fileManager = FileManager.default

    /// The extension source copied into the app bundle as a folder reference.
    var bundledExtensionURL: URL? {
        Bundle.main.url(forResource: "extension", withExtension: nil)
    }

    /// `Application Support/Maruko/ChromeExtension` inside the sandbox
    /// container. Chrome (unsandboxed) reads it fine; the install flow
    /// reveals it in Finder for drag-and-drop, so the path's ugliness never
    /// shows up in a file picker.
    var defaultExportURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maruko", isDirectory: true)
            .appendingPathComponent(Self.exportFolderName, isDirectory: true)
    }

    /// Copies the bundled extension to `destination` (default export
    /// location when nil), replacing any previous copy. Returns the folder
    /// Chrome should load.
    @discardableResult
    func exportBundledExtension(to destination: URL? = nil) throws -> URL {
        guard let source = bundledExtensionURL else {
            throw ExtensionInstallerError.bundledExtensionMissing
        }
        let target = destination ?? defaultExportURL

        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Copy to a temp sibling first so a failed copy never leaves a
        // half-written extension where Chrome might reload it.
        let staging = target
            .deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent)-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staging)

        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: target)
        }
        return target
    }

    func stateOfExport() -> ExportState {
        let exported = defaultExportURL
        guard let exportedVersion = Self.manifestVersion(at: exported) else {
            return .notExported
        }
        let bundledVersion = bundledExtensionURL.flatMap(Self.manifestVersion(at:)) ?? exportedVersion
        if exportedVersion == bundledVersion,
           bundledExtensionURL.map({ Self.contentsMatch($0, exported) }) == true {
            return .upToDate(exported)
        }
        return .outdated(
            exportedVersion: exportedVersion,
            bundledVersion: bundledVersion,
            url: exported
        )
    }

    static func manifestVersion(at directory: URL) -> String? {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return manifest["version"] as? String
    }

    static func contentsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsFiles = relativeFiles(in: lhs),
              let rhsFiles = relativeFiles(in: rhs),
              lhsFiles == rhsFiles else {
            return false
        }

        for file in lhsFiles {
            let lhsURL = lhs.appendingPathComponent(file)
            let rhsURL = rhs.appendingPathComponent(file)
            guard let lhsData = try? Data(contentsOf: lhsURL),
                  let rhsData = try? Data(contentsOf: rhsURL),
                  lhsData == rhsData else {
                return false
            }
        }
        return true
    }

    private static func relativeFiles(in directory: URL) -> [String]? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var files: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            files.append(String(url.path.dropFirst(directory.path.count + 1)))
        }
        return files.sorted()
    }
}
