//  ActFileCache.swift — Sudrf
//
//  Small disk cache for verified published PDF bytes. The provenance digest is
//  the cache key and is checked whenever a file is saved or read.

import CryptoKit
import Foundation
import PDFKit

public actor ActFileCache {
    private let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.directory = support
                .appendingPathComponent("Sudrf", isDirectory: true)
                .appendingPathComponent("published-acts", isDirectory: true)
        }
    }

    @discardableResult
    public func save(file: PublishedActFile) throws -> URL {
        let provenance = file.provenance
        guard Self.isVerifiedPDF(file.data, provenance: provenance) else {
            throw PublishedActFileError.extractionFailed
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = cacheURL(for: provenance)
        try file.data.write(to: url, options: .atomic)
        return url
    }

    /// Returns a URL only while its bytes still match the verified provenance.
    public func fileURL(provenance: PublishedActProvenance) -> URL? {
        guard provenance.format == .pdf, Self.isSafeHash(provenance.contentHash) else { return nil }
        let url = cacheURL(for: provenance)
        guard let data = try? Data(contentsOf: url), Self.isVerifiedPDF(data, provenance: provenance) else {
            return nil
        }
        return url
    }

    public func load(provenance: PublishedActProvenance) -> Data? {
        guard let url = fileURL(provenance: provenance),
              let data = try? Data(contentsOf: url),
              Self.isVerifiedPDF(data, provenance: provenance) else {
            return nil
        }
        return data
    }

    private func cacheURL(for provenance: PublishedActProvenance) -> URL {
        directory.appendingPathComponent(provenance.contentHash.lowercased())
            .appendingPathExtension("pdf")
    }

    private static func isVerifiedPDF(_ data: Data, provenance: PublishedActProvenance) -> Bool {
        guard provenance.format == .pdf,
              data.count <= ActFileLoader.Limits.production.maxDownloadBytes,
              provenance.byteCount == data.count,
              isSafeHash(provenance.contentHash),
              sha256(data) == provenance.contentHash.lowercased(),
              hasPDFHeader(data),
              let document = PDFDocument(data: data), !document.isLocked,
              document.pageCount > 0,
              document.pageCount <= ActFileLoader.Limits.production.maxPDFPages else {
            return false
        }
        return true
    }

    private static func isSafeHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hasPDFHeader(_ data: Data) -> Bool {
        let header = Data("%PDF-".utf8)
        let end = min(data.count, 1_024)
        guard end >= header.count else { return false }
        return (0...(end - header.count)).contains { offset in
            data[offset..<(offset + header.count)] == header
        }
    }
}
