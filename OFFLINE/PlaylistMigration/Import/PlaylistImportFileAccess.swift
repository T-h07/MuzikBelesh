import Foundation

struct PlaylistImportFileAccess {
    let root: URL

    /// Source access ends before parsing starts. The private directory is removed on
    /// success, failure or cancellation, and existing startup cleanup covers crashes.
    func withStagedFile<T>(source: URL, body: (URL) throws -> T) throws -> T {
        try Task.checkCancellation()
        guard source.isFileURL else { throw PlaylistImportProblem(location: "Selected file", reason: "A local Files-provider document is required.") }
        let directory = root.appendingPathComponent("playlist-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("source")
        try copyCoordinated(source: source, destination: staged)
        try Task.checkCancellation()
        return try body(staged)
    }

    private func copyCoordinated(source: URL, destination: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, copyError: Error?, copied = false
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            do {
                try Task.checkCancellation()
                let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size <= PlaylistImportLimits.inputBytes else {
                    throw PlaylistImportProblem(location: "Selected file", reason: "Select a regular file no larger than 20 MiB.")
                }
                guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw PlaylistImportProblem(location: "Selected file", reason: "Cannot create private staging file; check available storage.")
                }
                let input = try FileHandle(forReadingFrom: readable)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                var count = 0
                while true {
                    try Task.checkCancellation()
                    let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    count += chunk.count
                    guard count <= PlaylistImportLimits.inputBytes else { throw PlaylistImportProblem(location: "Selected file", reason: "File exceeds 20 MiB while reading.") }
                    try output.write(contentsOf: chunk)
                }
                guard count == size else { throw PlaylistImportProblem(location: "Selected file", reason: "The provider document changed while it was being copied; select it again.") }
                copied = true
            } catch { copyError = error }
        }
        if let copyError {
            if copyError is CancellationError || copyError is PlaylistImportProblem { throw copyError }
            throw PlaylistImportProblem(location: "Selected file", reason: "Cannot read or stage this document. Download it in Files and check available storage, then retry.")
        }
        guard coordinationError == nil, copied else {
            throw PlaylistImportProblem(location: "Selected file", reason: "The Files provider could not grant coordinated access. Download the document in Files and select it again.")
        }
    }
}

struct PlaylistMetadataFileImporter: PlaylistMigrationFileImporting, Sendable {
    let stagingRoot: URL

    func prepare(file: URL) async throws -> PlaylistImportReport {
        let worker = Task.detached(priority: .userInitiated) {
            try PlaylistImportFileAccess(root: stagingRoot).withStagedFile(source: file) { staged in
                try self.parse(Data(contentsOf: staged), filename: file.lastPathComponent)
            }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    /// The original contract has no place for partial failure diagnostics. Keep it
    /// strict; batch review uses prepare(file:) to retain independent candidates.
    func playlists(from file: URL) async throws -> [PlaylistMigrationSourcePlaylist] {
        let report = try await prepare(file: file)
        guard report.candidates.allSatisfy({ $0.source != nil }) else {
            throw PlaylistImportProblem(location: report.filename, reason: "At least one playlist is invalid. Use import review for per-playlist diagnostics.")
        }
        return report.candidates.compactMap(\.source)
    }

    func parse(_ data: Data, filename: String) throws -> PlaylistImportReport {
        try Task.checkCancellation()
        let filename = String(filename.components(separatedBy: .controlCharacters).joined(separator: " ").prefix(255))
        let ext = (filename as NSString).pathExtension.lowercased()
        guard data.count <= PlaylistImportLimits.inputBytes else { throw PlaylistImportProblem(location: filename, reason: "Input exceeds 20 MiB.") }
        guard ["json", "csv", "zip"].contains(ext) else { throw PlaylistImportProblem(location: filename, reason: "Choose a JSON, CSV or ZIP export.") }
        var candidates: [PlaylistImportCandidate] = [], notes: [String] = []
        func document(_ bytes: Data, member: String) throws {
            let memberExtension = (member as NSString).pathExtension.lowercased()
            guard ["json", "csv"].contains(memberExtension) else { notes.append("\(member) — Unsupported non-playlist file was ignored."); return }
            do {
                guard bytes.count <= PlaylistImportLimits.entryBytes else { throw PlaylistImportProblem(location: member, reason: "Playlist document exceeds 8 MiB.") }
                if memberExtension == "json" { candidates += try SpotifyPlaylistJSONParser().parse(bytes, container: filename, member: member, identityMember: ext == "zip" ? member : "") }
                else { candidates.append(try ExportifyCSVParser().parse(bytes, container: filename, member: member)) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                candidates.append(.init(location: member, format: memberExtension.uppercased(), name: (member as NSString).lastPathComponent, entryCount: nil, source: nil, diagnostics: [SpotifyPlaylistJSONParser.message(error, location: member)]))
            }
            guard candidates.count <= PlaylistImportLimits.playlists,
                  candidates.reduce(0, { $0 + ($1.entryCount ?? 0) }) <= PlaylistImportLimits.occurrences else {
                throw PlaylistImportProblem(location: filename, reason: "One review is limited to 100 playlists and 20,000 source occurrences. Split the export into smaller files.")
            }
        }
        if ext == "zip" { try PlaylistZIPReader().read(data) { try document($1, member: $0) } }
        else { try document(data, member: filename) }
        if candidates.isEmpty { notes.append("No supported playlists were found; nothing was imported.") }
        return .init(filename: filename, format: ext == "zip" ? "ZIP archive" : (ext == "json" ? "Spotify JSON" : "Exportify CSV"), candidates: candidates, notes: notes)
    }
}
