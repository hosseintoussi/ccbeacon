import Foundation
import CCBeaconCore

// Installs/updates ccbeacon's Claude Code integration at launch. This runs here, in the
// app, because Homebrew's post_install executes in a sandbox with a fake $HOME and can
// never write the user's real ~/.claude — the app is the only reliable place to do it.
// Running it on every launch also means each upgrade refreshes the hook script.
func syncClaudeIntegration() {
    let fm   = FileManager.default
    let home = NSHomeDirectory()

    // 1. Hook script: copy the bundled version when missing or different.
    let binDir = ((Bundle.main.executablePath ?? CommandLine.arguments[0]) as NSString)
        .deletingLastPathComponent
    let candidates = [
        binDir + "/../libexec/ccbeacon.sh",  // Homebrew keg: bin/ccbeacon → libexec/ccbeacon.sh
        binDir + "/../../ccbeacon.sh",       // dev build: .build/release/ccbeacon → repo root
        binDir + "/ccbeacon.sh",             // binary run straight from an unpacked tarball
    ].map { URL(fileURLWithPath: $0).standardized.path }

    let hookDst = home + "/.claude/hooks/ccbeacon.sh"
    if let src = candidates.first(where: { fm.fileExists(atPath: $0) }),
       let srcData = fm.contents(atPath: src),
       fm.contents(atPath: hookDst) != srcData {
        try? fm.createDirectory(atPath: home + "/.claude/hooks", withIntermediateDirectories: true)
        try? srcData.write(to: URL(fileURLWithPath: hookDst), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookDst)
    }

    // 2. settings.json: add missing hook entries. Never rewrite the file when nothing
    //    is missing, and never touch a file that doesn't parse.
    let settingsPath = home + "/.claude/settings.json"
    var settings: [String: Any] = [:]
    if let data = fm.contents(atPath: settingsPath) {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        settings = parsed
    }
    guard let merged = mergedHookSettings(settings),
          let out = try? JSONSerialization.data(withJSONObject: merged,
                                                options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? out.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
}
