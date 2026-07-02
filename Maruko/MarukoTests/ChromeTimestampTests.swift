import Foundation
import Testing
@testable import Maruko

struct ChromeTimestampTests {
    // 13_400_000_000_000_000 µs after 1601-01-01 is 1_755_526_400 s after 1970-01-01.
    @Test func convertsKnownConstant() {
        let date = ChromeTimestamp.date(from: 13_400_000_000_000_000)
        #expect(date.timeIntervalSince1970 == 1_755_526_400)
    }

    @Test func roundTripsThroughString() {
        let original = "13390123456789012"
        let date = ChromeTimestamp.date(from: original)
        #expect(date != nil)
        #expect(ChromeTimestamp.string(from: date!) == original)
    }

    @Test func rejectsNonNumericString() {
        #expect(ChromeTimestamp.date(from: "not-a-number") == nil)
    }
}
