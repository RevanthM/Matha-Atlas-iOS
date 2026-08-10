import AVFoundation
import Foundation
import PDFKit
import UIKit

enum AttachmentError: LocalizedError {
    case unsupportedDocument
    case unreadableImage
    case videoFramesUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedDocument:
            "That document type cannot be read locally. Use PDF, TXT, Markdown, JSON, CSV, or source code."
        case .unreadableImage:
            "The selected image could not be decoded."
        case .videoFramesUnavailable:
            "No usable frames could be extracted from that video."
        }
    }
}

actor AttachmentProcessor {
    static let shared = AttachmentProcessor()

    private let fileManager = FileManager.default

    private var attachmentsDirectory: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ChatAttachments", isDirectory: true)
    }

    func persistImage(_ image: UIImage, name: String = "Camera photo") throws -> ChatAttachment {
        guard let data = image.jpegData(compressionQuality: 0.88) else {
            throw AttachmentError.unreadableImage
        }
        let url = try write(data: data, extension: "jpg")
        return ChatAttachment(kind: .image, url: url, displayName: name)
    }

    func persistImageData(_ data: Data, name: String = "Photo") throws -> ChatAttachment {
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
            throw AttachmentError.unreadableImage
        }
        let url = try write(data: jpeg, extension: "jpg")
        return ChatAttachment(kind: .image, url: url, displayName: name)
    }

    func persistAudio(at sourceURL: URL, name: String? = nil) throws -> ChatAttachment {
        let url = try copySecurityScopedFile(sourceURL, preferredExtension: sourceURL.pathExtension)
        return ChatAttachment(
            kind: .audio,
            url: url,
            displayName: name ?? sourceURL.lastPathComponent
        )
    }

    func persistDocument(at sourceURL: URL) throws -> ChatAttachment {
        let ext = sourceURL.pathExtension.lowercased()
        let url = try copySecurityScopedFile(sourceURL, preferredExtension: ext)
        let text: String

        if ext == "pdf" {
            guard let pdf = PDFDocument(url: url), let extracted = pdf.string, !extracted.isEmpty else {
                throw AttachmentError.unsupportedDocument
            }
            text = extracted
        } else if Self.readableTextExtensions.contains(ext) {
            text = try String(contentsOf: url, encoding: .utf8)
        } else {
            throw AttachmentError.unsupportedDocument
        }

        let limit = 80_000
        let clipped = text.count > limit
            ? String(text.prefix(limit)) + "\n\n[Document truncated at \(limit) characters.]"
            : text
        return ChatAttachment(
            kind: .document,
            url: url,
            displayName: sourceURL.lastPathComponent,
            extractedText: clipped
        )
    }

    func persistVideoData(_ data: Data, name: String = "Video") async throws -> [ChatAttachment] {
        let source = try write(data: data, extension: "mov")
        return try await extractVideoFrames(from: source, name: name)
    }

    func extractVideoFrames(from sourceURL: URL, name: String? = nil) async throws -> [ChatAttachment] {
        let localURL = try copySecurityScopedFile(sourceURL, preferredExtension: sourceURL.pathExtension)
        let asset = AVURLAsset(url: localURL)
        let duration = try await asset.load(.duration)
        let seconds = max(CMTimeGetSeconds(duration), 0.1)
        let frameCount = min(6, max(1, Int(ceil(seconds / 4))))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let groupID = UUID()

        var results: [ChatAttachment] = []
        for index in 0..<frameCount {
            let position = seconds * (Double(index) + 0.5) / Double(frameCount)
            let time = CMTime(seconds: position, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                let uiImage = UIImage(cgImage: image)
                guard let data = uiImage.jpegData(compressionQuality: 0.82) else { continue }
                let frameURL = try write(data: data, extension: "jpg")
                results.append(
                    ChatAttachment(
                        kind: .videoFrame,
                        url: frameURL,
                        displayName: "\(name ?? sourceURL.lastPathComponent) • frame \(index + 1)",
                        groupID: groupID
                    )
                )
            }
        }

        guard !results.isEmpty else { throw AttachmentError.videoFramesUnavailable }
        return results
    }

    private func write(data: Data, extension fileExtension: String) throws -> URL {
        let directory = try prepareAttachmentsDirectory()
        let ext = fileExtension.isEmpty ? "bin" : fileExtension
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func copySecurityScopedFile(_ source: URL, preferredExtension: String) throws -> URL {
        let directory = try prepareAttachmentsDirectory()
        if source.deletingLastPathComponent() == directory { return source }

        let hasAccess = source.startAccessingSecurityScopedResource()
        defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }

        let ext = preferredExtension.isEmpty ? "bin" : preferredExtension
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    private func prepareAttachmentsDirectory() throws -> URL {
        let directory = attachmentsDirectory
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return directory
    }

    static let readableTextExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonl", "csv", "tsv", "xml", "yaml", "yml",
        "swift", "m", "mm", "h", "c", "cc", "cpp", "py", "js", "ts", "tsx", "jsx",
        "java", "kt", "kts", "rs", "go", "rb", "php", "sql", "sh", "zsh", "html", "css"
    ]
}
