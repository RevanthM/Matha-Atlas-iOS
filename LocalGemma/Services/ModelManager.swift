import Foundation

@MainActor
final class ModelManager: NSObject, ObservableObject {
    @Published private(set) var state: ModelState = .notInstalled
    @Published private(set) var installedSize: Int64 = 0

    let model = LocalModel.gemma4E2B

    private var downloadTask: URLSessionDownloadTask?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
        refresh()
    }

    var modelURL: URL? {
        if case .installed(let url) = state { return url }
        return nil
    }

    var modelsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Models", isDirectory: true)
    }

    private var destinationURL: URL {
        modelsDirectory.appendingPathComponent(model.filename)
    }

    func refresh() {
        do {
            try FileManager.default.createDirectory(
                at: modelsDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            guard FileManager.default.fileExists(atPath: destinationURL.path) else {
                installedSize = 0
                state = .notInstalled
                return
            }
            let values = try destinationURL.resourceValues(forKeys: [.fileSizeKey])
            installedSize = Int64(values.fileSize ?? 0)
            state = .installed(destinationURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func download() {
        guard downloadTask == nil else { return }
        do {
            let values = try modelsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = values.volumeAvailableCapacityForImportantUsage,
               available < model.expectedBytes + 500_000_000 {
                state = .failed(
                    "Not enough free storage. Free at least \(ByteCountFormatter.string(fromByteCount: model.expectedBytes + 500_000_000, countStyle: .file)) and try again."
                )
                return
            }
        } catch {
            // URLSession will still report a useful error if storage becomes unavailable.
        }
        state = .downloading(progress: 0, received: 0, total: model.expectedBytes)
        let request = URLRequest(url: model.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData)
        let task = session.downloadTask(with: request)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        refresh()
    }

    func importModel(from sourceURL: URL) async {
        state = .importing
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
            try FileManager.default.createDirectory(
                at: modelsDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let temporaryURL = modelsDirectory.appendingPathComponent(".importing-(UUID().uuidString).litertlm")
            try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
            try installDownloadedFile(at: temporaryURL)
            refresh()
        } catch {
            state = .failed("Could not import model: \(error.localizedDescription)")
        }
    }

    func deleteModel() throws {
        cancelDownload()
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        let cache = modelsDirectory.appendingPathComponent("CompilationCache", isDirectory: true)
        if FileManager.default.fileExists(atPath: cache.path) {
            try FileManager.default.removeItem(at: cache)
        }
        refresh()
    }

    private func installDownloadedFile(at temporaryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destinationURL
        try mutableDestination.setResourceValues(values)
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            let expected = totalBytesExpectedToWrite > 0
                ? totalBytesExpectedToWrite
                : self.model.expectedBytes
            let progress = expected > 0 ? Double(totalBytesWritten) / Double(expected) : 0
            self.state = .downloading(
                progress: min(max(progress, 0), 1),
                received: totalBytesWritten,
                total: expected
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("gemma-download-\(UUID().uuidString).litertlm")
            try FileManager.default.moveItem(at: location, to: staging)
            Task { @MainActor in
                do {
                    try self.installDownloadedFile(at: staging)
                    self.downloadTask = nil
                    self.refresh()
                } catch {
                    self.downloadTask = nil
                    self.state = .failed("Download finished, but installation failed: \(error.localizedDescription)")
                }
            }
        } catch {
            Task { @MainActor in
                self.downloadTask = nil
                self.state = .failed("Could not save the model: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let urlError = error as? URLError
        Task { @MainActor in
            self.downloadTask = nil
            if urlError?.code == .cancelled {
                self.refresh()
            } else {
                self.state = .failed("Model download failed: \(error.localizedDescription)")
            }
        }
    }
}
