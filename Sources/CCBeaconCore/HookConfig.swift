import Foundation

// The hook entries ccbeacon needs in ~/.claude/settings.json.
private let hookCommand = "~/.claude/hooks/ccbeacon.sh"
private let desiredHooks: [(event: String, matcher: String?, state: String)] = [
    ("SessionStart",     nil,                   "idle"),
    ("UserPromptSubmit", nil,                   "working"),
    ("Notification",     "permission_prompt",   "waiting"),
    ("Notification",     "elicitation_dialog",  "waiting"),
    ("Stop",             nil,                   "done"),
    ("StopFailure",      nil,                   "done"),
    ("SessionEnd",       nil,                   "done"),
]

// Returns settings with ccbeacon's hook entries added, or nil if nothing is missing.
// An event that already has any ccbeacon entry is left exactly as the user configured
// it; entries for other tools are never touched.
public func mergedHookSettings(_ settings: [String: Any]) -> [String: Any]? {
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    var changed = false

    let events = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "StopFailure", "SessionEnd"]
    for event in events {
        var entries = hooks[event] as? [[String: Any]] ?? []
        guard !entries.contains(where: { String(describing: $0).contains("ccbeacon") }) else { continue }
        for d in desiredHooks where d.event == event {
            var entry: [String: Any] = ["hooks": [["type": "command", "command": "\(hookCommand) \(d.state)"]]]
            if let m = d.matcher { entry["matcher"] = m }
            entries.append(entry)
        }
        hooks[event] = entries
        changed = true
    }

    guard changed else { return nil }
    var out = settings
    out["hooks"] = hooks
    return out
}
