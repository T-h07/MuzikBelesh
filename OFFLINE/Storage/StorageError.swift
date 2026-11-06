import Foundation

enum StorageError: LocalizedError, Equatable {
    case invalidPath
    case unsupportedAudio
    case missingFile
    case duplicate(trackID: String)
    case insufficientStorage
    case importIncomplete
    case databaseUnavailable(String)
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .invalidPath: return "The selected file path is not valid."
        case .unsupportedAudio: return "The file does not contain a supported audio track."
        case .missingFile: return "The managed audio file is no longer available."
        case .duplicate(let id): return "This audio is already in your library (track \(id))."
        case .insufficientStorage: return "There is not enough storage to import this audio file."
        case .importIncomplete: return "The import did not finish and was safely rolled back."
        case .databaseUnavailable(let message): return "Local library storage is unavailable: \(message)"
        case .exportFailed: return "The audio could not be exported."
        }
    }
}
