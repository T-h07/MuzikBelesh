import SwiftUI
import UIKit

// Owns a private, verified copy until the system export picker releases it.
final class PreparedAudioExport: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    private let directory: URL
    init(directory: URL, url: URL) { self.directory = directory; self.url = url }
    deinit { try? FileManager.default.removeItem(at: directory) }

    static func cleanupAbandoned(in root: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for entry in entries where entry.lastPathComponent.hasPrefix("Export-") {
            guard UUID(uuidString: String(entry.lastPathComponent.dropFirst(7))) != nil else { continue }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: entry)
        }
    }
}

struct AudioExportPicker: UIViewControllerRepresentable {
    let export: PreparedAudioExport
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [export.url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
}
