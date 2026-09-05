import Foundation
@testable import MonitorLog
import Testing

/// The hostname becomes a safe filename fragment: lowercased, and every
/// character outside [a-z0-9-_] replaced with a single underscore. Each
/// offending character becomes its own underscore — a run of them is not
/// collapsed — so "a  b" reads as "a__b".
struct HostnameSanitizationTests {
    @Test func sanitizesHostnames() {
        let cases: [(input: String, expected: String)] = [
            // Already clean.
            ("myhost", "myhost"),
            ("my-host", "my-host"),
            ("my_host", "my_host"),
            ("macbook-pro-2026", "macbook-pro-2026"),
            // Case is folded.
            ("MyHost", "myhost"),
            ("MacBook Pro 2026", "macbook_pro_2026"),
            // Dots and spaces become underscores.
            ("MacBook-Pro.local", "macbook-pro_local"),
            ("a.b.c", "a_b_c"),
            // The user's example.
            ("Jimmy's Macbook Pro 2026", "jimmy_s_macbook_pro_2026"),
            // Each offending character becomes its own underscore.
            ("a  b", "a__b"),
            ("!!!", "___"),
            // Leading and trailing spaces are not trimmed.
            (" host ", "_host_"),
            // Non-ASCII letters are not allowed.
            ("café", "caf_"),
            // A mix of allowed and replaced characters.
            ("Jimmy's-Macbook_Pro", "jimmy_s-macbook_pro"),
            // Empty stays empty.
            ("", ""),
        ]
        for (input, expected) in cases {
            #expect(CSVLogSink.sanitized(input) == expected, "sanitized(\(input))")
        }
    }

    @Test func resultIsAlwaysSafeForAFilename() {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        let inputs = [
            "Jimmy's Macbook Pro 2026",
            "MacBook-Pro.local",
            "a/b\\c:d*e?f\"g<h>i|j",
            "café 🍎",
            "  ",
        ]
        for input in inputs {
            let result = CSVLogSink.sanitized(input)
            #expect(
                result.allSatisfy { allowed.contains($0) },
                "sanitized(\(input)) = \(result)"
            )
        }
    }

    @Test func cannotEscapeTheDirectory() {
        // A hostname that tries to climb out of the log directory is flattened
        // to a single safe token, so it can never name a file elsewhere.
        #expect(CSVLogSink.sanitized("a/../b") == "a____b")
        #expect(CSVLogSink.sanitized("..") == "__")
    }
}
