import Foundation
import CCBeaconCore

// Minimal test runner — no framework needed, works with CommandLineTools.
// Run with: swift run CCBeaconTests

private var passed = 0, failed = 0

private func expect(_ got: some Equatable & CustomStringConvertible,
                    _ expected: some Equatable & CustomStringConvertible,
                    _ label: String, file: String = #fileID, line: Int = #line) {
    if "\(got)" == "\(expected)" {
        print("  ✓  \(label)")
        passed += 1
    } else {
        print("  ✗  \(label)")
        print("       got:      \(got)")
        print("       expected: \(expected)  (\(file):\(line))")
        failed += 1
    }
}

private func suite(_ name: String, _ body: () -> Void) {
    print("\n\(name)")
    body()
}

// MARK: - Test suites

suite("fmtElapsed") {
    expect(fmtElapsed(0),    "0s",   "0s")
    expect(fmtElapsed(1),    "1s",   "1s")
    expect(fmtElapsed(59),   "59s",  "59s")
    expect(fmtElapsed(60),   "1m",   "60s → 1m")
    expect(fmtElapsed(90),   "1m",   "90s → 1m")
    expect(fmtElapsed(3599), "59m",  "3599s → 59m")
    expect(fmtElapsed(3600), "1h0m", "3600s → 1h0m")
    expect(fmtElapsed(3661), "1h1m", "3661s → 1h1m")
    expect(fmtElapsed(7260), "2h1m", "7260s → 2h1m")
}

suite("fmtClock") {
    expect(fmtClock(0),    "0:00",  "0s")
    expect(fmtClock(47),   "0:47",  "47s")
    expect(fmtClock(134),  "2:14",  "134s")
    expect(fmtClock(3599), "59:59", "3599s")
    expect(fmtClock(3600), "1:00",  "3600s → 1:00 (h:mm)")
    expect(fmtClock(3661), "1:01",  "3661s → 1:01")
    expect(fmtClock(7384), "2:03",  "7384s → 2:03")
}

suite("fmtK") {
    expect(fmtK(0),         "0",      "0")
    expect(fmtK(999),       "999",    "999")
    expect(fmtK(1_000),     "1.0k",   "1k")
    expect(fmtK(1_500),     "1.5k",   "1.5k")
    expect(fmtK(12_345),    "12.3k",  "12.3k")
    expect(fmtK(1_000_000), "1.00M",  "1M")
    expect(fmtK(2_500_000), "2.50M",  "2.5M")
}

suite("cleanModel") {
    expect(cleanModel("claude-sonnet-4-5"), "sonnet-4-5", "strips claude- prefix")
    expect(cleanModel("claude-haiku-3-5"),  "haiku-3-5",  "strips claude- prefix")
    expect(cleanModel("claude-opus-4"),     "opus-4",     "strips claude- prefix")
    expect(cleanModel("gpt-4o"),            "gpt-4o",     "passthrough: no prefix")
    expect(cleanModel(""),                  "",           "passthrough: empty")
}

suite("Session.priority") {
    func s(_ state: String) -> Session {
        Session(id: "x", state: state, ts: 0, cwd: "/", transcriptPath: "",
                totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0, cost: 0, model: "")
    }
    expect(s("waiting").priority, 3, "waiting = 3")
    expect(s("working").priority, 2, "working = 2")
    expect(s("idle").priority,    1, "idle = 1")
    expect(s("other").priority,   0, "unknown = 0")

    let sorted = [s("idle"), s("waiting"), s("working")].sorted { $0.priority > $1.priority }
    expect(sorted[0].state, "waiting", "sort: waiting first")
    expect(sorted[1].state, "working", "sort: working second")
    expect(sorted[2].state, "idle",    "sort: idle last")
}

suite("Session.dirName") {
    func s(_ cwd: String) -> Session {
        Session(id: "x", state: "working", ts: 0, cwd: cwd, transcriptPath: "",
                totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0, cost: 0, model: "")
    }
    expect(s("/Users/alice/code/myproject").dirName, "myproject", "last path component")
    expect(s("/Users/alice/code/my-app").dirName,    "my-app",    "hyphenated name")
    expect(s("myproject").dirName,                   "myproject", "bare name")
}

suite("fmtFull") {
    expect(fmtFull(0),       "0",         "zero")
    expect(fmtFull(999),     "999",       "under 1k")
    expect(fmtFull(1_000),   "1,000",     "1k with comma")
    expect(fmtFull(2_981),   "2,981",     "thousands")
    expect(fmtFull(1_000_000), "1,000,000", "million")
}

suite("dailyLabel") {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"

    let today     = fmt.string(from: Date())
    let yesterday = fmt.string(from: Date(timeIntervalSinceNow: -86400))

    expect(dailyLabel(for: today),     "Today",     "today → Today")
    expect(dailyLabel(for: yesterday), "Yesterday", "yesterday → Yesterday")
    expect(dailyLabel(for: "2026-06-24", relativeTo: Date(timeIntervalSinceNow: 86400 * 5)),
           "Jun 24", "older date → MMM d")
    expect(dailyLabel(for: "2026-01-01", relativeTo: Date(timeIntervalSinceNow: 86400 * 30)),
           "Jan 1",  "Jan 1")
    expect(dailyLabel(for: "bad-date"),  "bad-date", "unparseable → passthrough")
}

// MARK: - Summary

print("\n" + String(repeating: "─", count: 40))
if failed == 0 {
    print("✓  All \(passed) tests passed")
} else {
    print("✗  \(failed) failed, \(passed) passed")
    exit(1)
}
