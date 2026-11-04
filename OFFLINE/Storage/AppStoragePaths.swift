import Foundation

struct AppStoragePaths {
    let fileManager: FileManager
    let documents: URL
    let music: URL
    let artwork: URL
    let applicationSupport: URL
    let caches: URL
    let imports: URL
    let exports: URL
    let thumbnails: URL
    let deletions: URL
    let database: URL

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        documents = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        applicationSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("MuzikBelesh", isDirectory: true)
        caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("MuzikBelesh", isDirectory: true)
        music = documents.appendingPathComponent("Music", isDirectory: true)
        artwork = documents.appendingPathComponent("Artwork", isDirectory: true)
        imports = caches.appendingPathComponent("Imports", isDirectory: true)
        exports = caches.appendingPathComponent("Exports", isDirectory: true)
        thumbnails = caches.appendingPathComponent("Thumbnails", isDirectory: true)
        database = applicationSupport.appendingPathComponent("muzikbelesh.sqlite")
        deletions = applicationSupport.appendingPathComponent("DeletionStaging", isDirectory: true)
        try createDirectories()
    }

    init(root: URL, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        applicationSupport = root.appendingPathComponent("Application Support/MuzikBelesh", isDirectory: true)
        caches = root.appendingPathComponent("Caches/MuzikBelesh", isDirectory: true)
        music = documents.appendingPathComponent("Music", isDirectory: true)
        artwork = documents.appendingPathComponent("Artwork", isDirectory: true)
        imports = caches.appendingPathComponent("Imports", isDirectory: true)
        exports = caches.appendingPathComponent("Exports", isDirectory: true)
        thumbnails = caches.appendingPathComponent("Thumbnails", isDirectory: true)
        database = applicationSupport.appendingPathComponent("muzikbelesh.sqlite")
        deletions = applicationSupport.appendingPathComponent("DeletionStaging", isDirectory: true)
        try createDirectories()
    }

    func createDirectories() throws {
        for url in [documents, music, artwork, applicationSupport, caches, imports, exports, thumbnails, deletions] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func relativeURL(_ relativePath: String, in root: URL) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.contains(".."), !relativePath.hasPrefix("/") else { throw StorageError.invalidPath }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var url = resolvedRoot
        for component in relativePath.split(separator: "/") {
            url = url.appendingPathComponent(String(component)).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(resolvedRoot.path + "/") else { throw StorageError.invalidPath }
        }
        return url
    }

    func musicURL(relativePath: String) throws -> URL { try relativeURL(relativePath, in: music) }
    func artworkURL(relativePath: String) throws -> URL { try relativeURL(relativePath, in: artwork) }
}
