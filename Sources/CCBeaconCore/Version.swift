import Foundation

public let appVersion = "1.0.0"

// Dev if the binary isn't in a standard install location (Homebrew or /usr/local).
public var isDevBuild: Bool {
    let path = CommandLine.arguments.first ?? ""
    return !path.hasPrefix("/opt/homebrew") && !path.hasPrefix("/usr/local")
}
