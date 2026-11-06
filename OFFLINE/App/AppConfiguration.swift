import Foundation

struct AppConfiguration: Equatable {
    let displayName: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let commit: String
    let buildDate: String
    let buildConfiguration: String
    static func current(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> AppConfiguration {
        AppConfiguration(displayName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Muzik Belesh", bundleIdentifier: bundle.bundleIdentifier ?? "com.th07.muzikbelesh", version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0", build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1", commit: bundle.object(forInfoDictionaryKey: "MBBuildCommit") as? String ?? "unknown", buildDate: bundle.object(forInfoDictionaryKey: "MBBuildDate") as? String ?? "unknown", buildConfiguration: environment["CONFIGURATION"] ?? (environment["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]?.contains("DEBUG") == true ? "Debug" : "Release"))
    }
}

