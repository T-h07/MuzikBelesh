import Foundation

struct AppConfiguration: Equatable {
    let displayName: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let buildConfiguration: String
    static func current(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> AppConfiguration {
        AppConfiguration(displayName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OFFLINE", bundleIdentifier: bundle.bundleIdentifier ?? "com.th07.muzikbelesh", version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0", build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1", buildConfiguration: environment["CONFIGURATION"] ?? (environment["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]?.contains("DEBUG") == true ? "Debug" : "Release"))
    }
}

