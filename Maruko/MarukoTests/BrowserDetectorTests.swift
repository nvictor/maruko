import Foundation
import Testing
@testable import Maruko

struct BrowserDetectorTests {
    private func makeAppSupport() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDetectorTests-\(UUID().uuidString)", isDirectory: true)

        let chrome = root.appendingPathComponent("Google/Chrome", isDirectory: true)
        for profile in ["Default", "Profile 1", "System Profile", "Guest Profile", "Empty Profile"] {
            let dir = chrome.appendingPathComponent(profile, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if profile != "Empty Profile" {
                try Data(#"{"roots": {}}"#.utf8).write(to: dir.appendingPathComponent("Bookmarks"))
            }
        }

        let localState: [String: Any] = [
            "profile": [
                "info_cache": [
                    "Default": ["name": "Personal"],
                    "Profile 1": ["name": "Work"],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: localState)
            .write(to: chrome.appendingPathComponent("Local State"))

        return root
    }

    @Test func findsProfilesWithBookmarksAndHumanNames() throws {
        let appSupport = try makeAppSupport()
        let profiles = BrowserDetector.profiles(for: .chrome, applicationSupportURL: appSupport)

        #expect(profiles.map(\.directoryName).sorted() == ["Default", "Profile 1"])
        #expect(profiles.map(\.displayName).sorted() == ["Personal", "Work"])
        #expect(profiles.allSatisfy { $0.bookmarksFileURL.lastPathComponent == "Bookmarks" })
    }

    @Test func excludesSystemGuestAndBookmarklessProfiles() throws {
        let appSupport = try makeAppSupport()
        let names = BrowserDetector.profiles(for: .chrome, applicationSupportURL: appSupport)
            .map(\.directoryName)

        #expect(!names.contains("System Profile"))
        #expect(!names.contains("Guest Profile"))
        #expect(!names.contains("Empty Profile"))
    }

    @Test func missingDataDirectoryYieldsNoProfiles() throws {
        let appSupport = try makeAppSupport()
        #expect(BrowserDetector.profiles(for: .brave, applicationSupportURL: appSupport).isEmpty)
    }

    @Test func unsupportedBrowsersHaveNoDataDirectory() {
        #expect(!BrowserKind.safari.isSupported)
        #expect(!BrowserKind.firefox.isSupported)
        #expect(!BrowserKind.orion.isSupported)
        #expect(BrowserKind.chrome.isSupported)
        #expect(BrowserKind.arc.isSupported)
    }
}
