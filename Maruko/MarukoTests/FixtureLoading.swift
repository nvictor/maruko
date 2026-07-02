import Foundation

private final class FixtureLocator {}

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureLocator.self)
        guard let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw NSError(
                domain: "MarukoTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing fixture \(name).json in test bundle"]
            )
        }
        return try Data(contentsOf: url)
    }

    static func dictionary(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data(name)) as? [String: Any] ?? [:]
    }
}
