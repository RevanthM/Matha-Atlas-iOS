import Foundation
import NaturalLanguage
import PDFKit

struct KnowledgeChunk: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let vector: [Double]
}

struct KnowledgeDocument: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let importedAt: Date
    let characterCount: Int
    let chunks: [KnowledgeChunk]
}

private struct KnowledgeArchive: Codable {
    let schemaVersion: Int
    let documents: [KnowledgeDocument]

    init(schemaVersion: Int = 1, documents: [KnowledgeDocument]) {
        self.schemaVersion = schemaVersion
        self.documents = documents
    }
}

@MainActor
final class KnowledgeStore: ObservableObject {
    static let shared = KnowledgeStore()

    @Published private(set) var documents: [KnowledgeDocument] = []
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress = ""
    @Published var errorMessage: String?

    private let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    private let readableExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonl", "csv", "tsv", "xml", "yaml", "yml",
        "swift", "m", "mm", "h", "c", "cc", "cpp", "py", "js", "ts", "tsx", "jsx",
        "java", "kt", "kts", "rs", "go", "rb", "php", "sql", "sh", "zsh", "html", "css"
    ]

    private init() {
        do {
            let data = try Data(contentsOf: archiveURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            documents = try decoder.decode(KnowledgeArchive.self, from: data).documents
        } catch {
            documents = []
        }
    }

    var chunkCount: Int {
        documents.reduce(0) { $0 + $1.chunks.count }
    }

    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        errorMessage = nil
        defer {
            isImporting = false
            importProgress = ""
        }

        for (fileIndex, url) in urls.enumerated() {
            importProgress = "Reading \(url.lastPathComponent) (\(fileIndex + 1) of \(urls.count))"
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

            do {
                let text = try extractText(from: url)
                let pieces = chunks(from: text)
                var indexedChunks: [KnowledgeChunk] = []
                indexedChunks.reserveCapacity(pieces.count)

                for (chunkIndex, piece) in pieces.enumerated() {
                    importProgress = "Indexing \(url.lastPathComponent) • \(chunkIndex + 1) of \(pieces.count)"
                    indexedChunks.append(
                        KnowledgeChunk(id: UUID(), text: piece, vector: embed(piece))
                    )
                    if chunkIndex.isMultiple(of: 4) { await Task.yield() }
                }

                let document = KnowledgeDocument(
                    id: UUID(),
                    name: url.lastPathComponent,
                    importedAt: Date(),
                    characterCount: text.count,
                    chunks: indexedChunks
                )
                documents.removeAll { $0.name == document.name }
                documents.append(document)
                try persist()
            } catch {
                errorMessage = "Could not index \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func delete(_ document: KnowledgeDocument) {
        documents.removeAll { $0.id == document.id }
        do {
            try persist()
        } catch {
            errorMessage = "Knowledge library could not be saved: \(error.localizedDescription)"
        }
    }

    func removeAll() {
        documents = []
        do {
            try persist()
        } catch {
            errorMessage = "Knowledge library could not be cleared: \(error.localizedDescription)"
        }
    }

    func context(for query: String, limit: Int = 4, maximumCharacters: Int = 6_000) -> String? {
        guard !documents.isEmpty else { return nil }
        let queryVector = embed(query)
        let ranked = documents.flatMap { document in
            document.chunks.map { chunk in
                (document.name, chunk.text, cosineSimilarity(queryVector, chunk.vector))
            }
        }
        .sorted { $0.2 > $1.2 }
        .prefix(limit)

        var remaining = maximumCharacters
        var excerpts: [String] = []
        for result in ranked where remaining > 0 {
            let excerpt = String(result.1.prefix(remaining))
            excerpts.append("[Source: \(result.0)]\n\(excerpt)")
            remaining -= excerpt.count
        }
        return excerpts.isEmpty ? nil : excerpts.joined(separator: "\n\n")
    }

    private func extractText(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        let text: String
        if ext == "pdf" {
            guard let pdf = PDFDocument(url: url), let extracted = pdf.string else {
                throw KnowledgeError.unreadableDocument
            }
            text = extracted
        } else if readableExtensions.contains(ext) {
            text = try String(contentsOf: url, encoding: .utf8)
        } else {
            throw KnowledgeError.unsupportedDocument
        }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw KnowledgeError.emptyDocument }
        return String(normalized.prefix(500_000))
    }

    private func chunks(from text: String, targetSize: Int = 1_400, overlap: Int = 180) -> [String] {
        var results: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let end = text.index(start, offsetBy: targetSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { results.append(chunk) }
            if end == text.endIndex { break }
            start = text.index(end, offsetBy: -min(overlap, text.distance(from: start, to: end)))
        }
        return results
    }

    private func embed(_ text: String) -> [Double] {
        if let vector = sentenceEmbedding?.vector(for: String(text.prefix(4_000))), !vector.isEmpty {
            return normalized(vector)
        }

        var vector = [Double](repeating: 0, count: 256)
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let hash = token.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
                ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }
            let index = Int(hash % UInt64(vector.count))
            vector[index] += (hash & 1) == 0 ? 1 : -1
        }
        return normalized(vector)
    }

    private func normalized(_ vector: [Double]) -> [Double] {
        let magnitude = sqrt(vector.reduce(0) { $0 + ($1 * $1) })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    private func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.infinity }
        return zip(lhs, rhs).reduce(0) { $0 + ($1.0 * $1.1) }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(KnowledgeArchive(documents: documents))
        try data.write(to: archiveURL, options: .atomic)
    }

    private var archiveURL: URL {
        get throws {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalGemma", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableRoot = root
            try? mutableRoot.setResourceValues(values)
            return root.appendingPathComponent("KnowledgeIndex.json")
        }
    }
}

private enum KnowledgeError: LocalizedError {
    case unsupportedDocument
    case unreadableDocument
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .unsupportedDocument: "Use a PDF, text, Markdown, CSV, JSON, or source-code file."
        case .unreadableDocument: "The document could not be read locally."
        case .emptyDocument: "The document contains no readable text."
        }
    }
}
