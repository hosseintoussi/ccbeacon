import Foundation
import Darwin

// MARK: - Paths

public let sessionsDir  = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/cc-sessions")
// MARK: - Token cache

private struct TokenSnapshot {
    let input: Int, output: Int, cache: Int, model: String, mtime: Date
}
private var tokenCache: [String: TokenSnapshot] = [:]

public func readTokens(_ transcriptPath: String) -> (input: Int, output: Int, cache: Int, model: String) {
    guard !transcriptPath.isEmpty,
          let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
          let mtime = attrs[.modificationDate] as? Date
    else { return (0, 0, 0, "") }

    if let c = tokenCache[transcriptPath], c.mtime == mtime {
        return (c.input, c.output, c.cache, c.model)
    }

    var i = 0, o = 0, c = 0, model = ""
    if let text = try? String(contentsOfFile: transcriptPath, encoding: .utf8) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data  = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (entry["type"] as? String) == "assistant",
                  let msg   = entry["message"] as? [String: Any],
                  let usage = msg["usage"]     as? [String: Any]
            else { continue }
            i += usage["input_tokens"]                 as? Int ?? 0
            o += usage["output_tokens"]                as? Int ?? 0
            c += (usage["cache_creation_input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"]    as? Int ?? 0)
            if model.isEmpty { model = msg["model"] as? String ?? "" }
        }
    }

    tokenCache[transcriptPath] = TokenSnapshot(input: i, output: o, cache: c, model: model, mtime: mtime)
    return (input: i, output: o, cache: c, model: model)
}

// MARK: - Models

public struct Session {
    public let id: String
    public let state: String
    public let ts: TimeInterval
    public let cwd: String
    public let transcriptPath: String
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int
    public let cost: Double
    public let model: String
    public let tty: String
    public let terminal: String

    public init(id: String, state: String, ts: TimeInterval, cwd: String, transcriptPath: String,
                totalTokens: Int, inputTokens: Int, outputTokens: Int, cacheTokens: Int,
                cost: Double, model: String, tty: String = "", terminal: String = "") {
        self.id = id; self.state = state; self.ts = ts; self.cwd = cwd
        self.transcriptPath = transcriptPath; self.totalTokens = totalTokens
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens; self.cost = cost; self.model = model
        self.tty = tty; self.terminal = terminal
    }

    public var elapsed: Int { max(0, Int(Date().timeIntervalSince1970 - ts)) }

    public var dirName: String {
        let last = URL(fileURLWithPath: cwd).lastPathComponent
        return last.isEmpty ? cwd : last
    }

    public var priority: Int {
        switch state {
        case "waiting": return 3
        case "working": return 2
        case "idle":    return 1
        default:        return 0
        }
    }
}

// MARK: - Loading

public func loadSessions() -> [Session] {
    let fm  = FileManager.default
    let now = Date().timeIntervalSince1970
    guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

    return files.compactMap { file -> Session? in
        guard file.hasSuffix(".json") else { return nil }
        let path = (sessionsDir as NSString).appendingPathComponent(file)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let rawState       = json["state"]           as? String       ?? ""
        let ts             = json["ts"]              as? TimeInterval ?? 0
        let transcriptPath = json["transcript_path"] as? String       ?? ""

        // If the session is "waiting" but the transcript has been written to since
        // the waiting state was set, Claude has resumed (e.g. after a tool approval
        // that doesn't fire UserPromptSubmit). Use a 5-second buffer so the initial
        // transcript write that triggered the Notification doesn't false-positive.
        var state: String
        if rawState == "waiting", !transcriptPath.isEmpty,
           let attrs = try? fm.attributesOfItem(atPath: transcriptPath),
           let mtime = attrs[.modificationDate] as? Date,
           mtime.timeIntervalSince1970 > ts + 5.0 {
            state = "working"
        } else {
            state = rawState
        }

        let storedPid = json["claude_pid"] as? Int ?? 0
        // kill(pid, 0) returns ESRCH only when the process is truly gone (no permission needed).
        let killResult = storedPid > 0 ? kill(pid_t(storedPid), 0) : 0
        let killErrno  = errno
        let pidDead    = storedPid > 0 && killResult != 0 && killErrno == ESRCH

        // "done" means Claude finished its last response — the process may still be open.
        // Resolve to "idle" when the PID is alive so open sessions stay visible.
        if state == "done" && storedPid > 0 && !pidDead {
            state = "idle"
        }

        let stale: Bool
        if state == "idle" {
            if storedPid > 0 {
                stale = pidDead  // trust PID; file deleted immediately when PID dies
            } else {
                stale = (now - ts) > 7200  // no PID stored — time-based fallback
            }
        } else if state == "done" {
            if storedPid > 0 {
                stale = pidDead  // remove immediately when process exits
            } else {
                stale = (now - ts) > 30  // no PID stored — time-based fallback
            }
        } else if state == "working" {
            if pidDead {
                // Claude process is gone — killed session, remove immediately.
                stale = true
            } else if storedPid > 0 {
                // PID is alive — trust it regardless of time.
                stale = false
            } else {
                // No PID stored (old session file) — fall back to transcript mtime.
                if let attrs    = try? fm.attributesOfItem(atPath: transcriptPath),
                   let modified = attrs[.modificationDate] as? Date {
                    stale = (now - modified.timeIntervalSince1970) > 600
                } else {
                    stale = (now - ts) > 1800
                }
            }
        } else if state == "waiting" {
            stale = pidDead || (now - ts) > 14400
        } else {
            stale = (now - ts) > 14400
        }

        if stale { try? fm.removeItem(atPath: path); return nil }

        let tok = readTokens(transcriptPath)
        return Session(
            id:             json["session_id"]    as? String ?? file,
            state:          state,
            ts:             ts,
            cwd:            json["cwd"]           as? String ?? "",
            transcriptPath: transcriptPath,
            totalTokens:    tok.input + tok.output + tok.cache,
            inputTokens:    tok.input,
            outputTokens:   tok.output,
            cacheTokens:    tok.cache,
            cost:           0,
            model:          tok.model,
            tty:            json["tty"]           as? String ?? "",
            terminal:       json["terminal"]      as? String ?? ""
        )
    }.sorted { $0.priority > $1.priority }
}

// MARK: - Formatters

public func fmtElapsed(_ s: Int) -> String {
    if s < 60   { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h\((s % 3600) / 60)m"
}

public func fmtBarTime(_ s: Int) -> String {
    if s < 60    { return "\(s)s" }
    if s < 3600  { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

public func fmtK(_ n: Int) -> String {
    if n == 0        { return "0" }
    if n < 1_000     { return "\(n)" }
    if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return String(format: "%.2fM", Double(n) / 1_000_000)
}

public func fmtClock(_ s: Int) -> String {
    if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
    return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
}

public func cleanModel(_ m: String) -> String { m.hasPrefix("claude-") ? String(m.dropFirst(7)) : m }
