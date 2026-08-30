//  ActFileLoader.swift — Sudrf
//
//  Verified ingestion for published file acts. The source HTML is only a
//  pointer: a response becomes an act only after its bytes and native parser
//  both agree that it is a readable PDF, DOC, or DOCX file.

import AppKit
import CryptoKit
import Foundation
import PDFKit

public enum PublishedActFormat: String, Sendable, Codable, Equatable {
    case pdf
    case doc
    case docx

    var fileExtension: String { rawValue }
}

/// Provenance of a verified published file. It intentionally contains no URL
/// query, fragment, credentials, cookie, or response body.
public struct PublishedActProvenance: Sendable, Codable, Equatable {
    public let sourceURL: URL
    public let finalURL: URL
    public let format: PublishedActFormat
    /// Normalized `Content-Type` response value without parameters. This is
    /// evidence only; `format` is determined from bytes and parser success.
    public let contentType: String?
    /// SHA-256 of the downloaded bytes, distinct from `ActDocument.sourceHash`.
    public let contentHash: String
    public let byteCount: Int
    public let fetchedAt: Date
    public let extractorVersion: Int

    public init(sourceURL: URL, finalURL: URL, format: PublishedActFormat,
                contentType: String?, contentHash: String, byteCount: Int,
                fetchedAt: Date, extractorVersion: Int) {
        self.sourceURL = sourceURL
        self.finalURL = finalURL
        self.format = format
        self.contentType = contentType
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.fetchedAt = fetchedAt
        self.extractorVersion = extractorVersion
    }
}

public struct PublishedActFile: Sendable, Equatable {
    public let text: String
    public let provenance: PublishedActProvenance

    public init(text: String, provenance: PublishedActProvenance) {
        self.text = text
        self.provenance = provenance
    }
}

/// Deliberately terse: a rejected response must not leak a URL query, HTML, or
/// other potentially sensitive response details into UI diagnostics.
public enum PublishedActFileError: Error, LocalizedError, Sendable, Equatable {
    case unsafeSourceURL
    case unsafeFinalURL
    case unexpectedHTTPStatus(Int)
    case downloadTooLarge(limit: Int)
    case htmlResponse
    case incompatibleContentType
    case unsupportedFormat
    case unsafeDOCX
    case tooManyPDFPages(limit: Int)
    case extractedTextTooLarge(limit: Int)
    case noExtractableText
    case extractionFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeSourceURL, .unsafeFinalURL:
            "Ссылка на опубликованный акт ведёт за пределы портала суда."
        case .unexpectedHTTPStatus:
            "Суд не отдал файл судебного акта."
        case .downloadTooLarge:
            "Файл судебного акта слишком большой для безопасной обработки."
        case .htmlResponse:
            "Вместо файла судебного акта суд вернул HTML-страницу."
        case .incompatibleContentType:
            "Тип ответа суда не соответствует опубликованному документу."
        case .unsupportedFormat:
            "Формат опубликованного файла не поддерживается."
        case .unsafeDOCX:
            "Файл DOCX не прошёл безопасную проверку."
        case .tooManyPDFPages:
            "PDF содержит слишком много страниц для безопасной обработки."
        case .extractedTextTooLarge:
            "Извлечённый текст судебного акта слишком большой."
        case .noExtractableText:
            "В опубликованном файле нет пригодного для поиска текста."
        case .extractionFailed:
            "Не удалось извлечь текст из опубликованного файла."
        }
    }
}

/// Keeps the file-importing AppKit/PDFKit calls away from SwiftUI's main actor.
/// It is intentionally tiny and has no persistence responsibility.
actor ActFileLoader {
    struct Limits: Sendable, Equatable {
        let maxDownloadBytes: Int
        let maxExtractedTextBytes: Int
        let maxPDFPages: Int
        let maxDOCXEntries: Int
        let maxDOCXUncompressedBytes: Int
        let maxDOCXCompressionRatio: Int

        static let production = Limits(
            maxDownloadBytes: 25 * 1024 * 1024,
            maxExtractedTextBytes: 5 * 1024 * 1024,
            maxPDFPages: 500,
            maxDOCXEntries: 512,
            maxDOCXUncompressedBytes: 40 * 1024 * 1024,
            maxDOCXCompressionRatio: 100)
    }

    static let extractorVersion = 1

    let limits: Limits
    private let now: @Sendable () -> Date

    init(limits: Limits = .production, now: @escaping @Sendable () -> Date = { .now }) {
        self.limits = limits
        self.now = now
    }

    func extract(data: Data, sourceURL: URL, finalURL: URL,
                 contentType: String?) throws -> PublishedActFile {
        try Task.checkCancellation()
        guard data.count <= limits.maxDownloadBytes else {
            throw PublishedActFileError.downloadTooLarge(limit: limits.maxDownloadBytes)
        }

        let normalizedType = Self.normalizedContentType(contentType)
        if Self.isExplicitHTMLContentType(normalizedType) || Self.looksLikeHTML(data) {
            throw PublishedActFileError.htmlResponse
        }

        let format = try classify(data)
        try Self.validate(contentType: normalizedType, matches: format)

        let extracted: String
        do {
            extracted = try extractText(data: data, format: format)
        } catch let error as PublishedActFileError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PublishedActFileError.extractionFailed
        }

        let text = ActParagraphizer.normalizedText(Self.removingUnsafeControlCharacters(extracted))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PublishedActFileError.noExtractableText }
        guard text.lengthOfBytes(using: .utf8) <= limits.maxExtractedTextBytes else {
            throw PublishedActFileError.extractedTextTooLarge(limit: limits.maxExtractedTextBytes)
        }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let provenance = PublishedActProvenance(
            sourceURL: Self.sanitizedURL(sourceURL), finalURL: Self.sanitizedURL(finalURL),
            format: format, contentType: normalizedType, contentHash: hash,
            byteCount: data.count, fetchedAt: now(), extractorVersion: Self.extractorVersion)
        return PublishedActFile(text: text, provenance: provenance)
    }

    private func classify(_ data: Data) throws -> PublishedActFormat {
        if Self.hasPDFHeader(data) { return .pdf }
        if Self.hasPrefix(data, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return .doc }
        if Self.hasPrefix(data, [0x50, 0x4B, 0x03, 0x04]) {
            try DOCXPreflight.validate(data, limits: limits)
            return .docx
        }
        throw PublishedActFileError.unsupportedFormat
    }

    private func extractText(data: Data, format: PublishedActFormat) throws -> String {
        switch format {
        case .pdf:
            return try extractPDFText(data)
        case .doc, .docx:
            return try extractOfficeText(data: data, format: format)
        }
    }

    private func extractPDFText(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data), !document.isLocked else {
            throw PublishedActFileError.extractionFailed
        }
        guard document.pageCount > 0 else { throw PublishedActFileError.noExtractableText }
        guard document.pageCount <= limits.maxPDFPages else {
            throw PublishedActFileError.tooManyPDFPages(limit: limits.maxPDFPages)
        }

        var parts: [String] = []
        var byteCount = 0
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let pageText = document.page(at: pageIndex)?.string else { continue }
            let pageBytes = pageText.lengthOfBytes(using: .utf8)
            guard pageBytes <= limits.maxExtractedTextBytes,
                  byteCount <= limits.maxExtractedTextBytes - pageBytes else {
                throw PublishedActFileError.extractedTextTooLarge(limit: limits.maxExtractedTextBytes)
            }
            byteCount += pageBytes
            parts.append(pageText)
        }
        return parts.joined(separator: "\n\n")
    }

    private func extractOfficeText(data: Data, format: PublishedActFormat) throws -> String {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sudrf-act-\(UUID().uuidString).\(format.fileExtension)")
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw PublishedActFileError.extractionFailed
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let documentType: NSAttributedString.DocumentType = switch format {
        case .doc: .docFormat
        case .docx: .officeOpenXML
        case .pdf: throw PublishedActFileError.unsupportedFormat
        }
        do {
            return try NSAttributedString(
                url: fileURL, options: [.documentType: documentType], documentAttributes: nil).string
        } catch {
            throw PublishedActFileError.extractionFailed
        }
    }

    static func normalizedContentType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let type = raw.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return type?.isEmpty == false ? type : nil
    }

    static func sanitizedURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    static func hasPrefix(_ data: Data, _ prefix: [UInt8]) -> Bool {
        data.count >= prefix.count && zip(prefix.indices, prefix).allSatisfy { index, byte in
            data[index] == byte
        }
    }

    private static func removingUnsafeControlCharacters(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            let value = scalar.value
            guard value != 0, value != 0xFFFC,
                  value == 0x09 || value == 0x0A || (value >= 0x20 && value != 0x7F) else {
                continue
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// ISO 32000 permits a binary comment before the PDF header. It is still
    /// bounded tightly so an arbitrary response cannot masquerade as a PDF.
    private static func hasPDFHeader(_ data: Data) -> Bool {
        let header = [UInt8]([0x25, 0x50, 0x44, 0x46, 0x2D])
        let end = min(data.count, 1_024)
        guard end >= header.count else { return false }
        return (0...(end - header.count)).contains { offset in
            header.indices.allSatisfy { index in data[offset + index] == header[index] }
        }
    }

    private static func isExplicitHTMLContentType(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        return contentType == "text/html" || contentType == "application/xhtml+xml"
    }

    private static func looksLikeHTML(_ data: Data) -> Bool {
        let prefix = Data(data.prefix(16 * 1024))
        let utf8 = String(decoding: prefix, as: UTF8.self).lowercased()
        let cp1251 = Cyrillic1251.decode(prefix)?.lowercased() ?? ""
        let markers = ["<!doctype html", "<html", "<head", "<body", "<form", "<script"]
        return markers.contains { utf8.contains($0) || cp1251.contains($0) }
    }

    private static func validate(contentType: String?, matches format: PublishedActFormat) throws {
        guard let contentType else { return }
        let generic = ["application/octet-stream", "application/octect-stream", "binary/octet-stream",
                       "application/binary", "application/download", "application/x-download"]
        guard !generic.contains(contentType) else { return }
        let accepted: Set<String> = switch format {
        case .pdf:
            ["application/pdf", "application/x-pdf"]
        case .doc:
            ["application/msword", "application/doc", "application/vnd.ms-word"]
        case .docx:
            ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"]
        }
        guard accepted.contains(contentType) else {
            throw PublishedActFileError.incompatibleContentType
        }
    }
}

/// Narrow policy shared by the file transport and provenance loader. MGS links
/// are same-site HTTPS; accepting a broad suffix here would make redirects a
/// hidden new source.
public enum PublishedActURLPolicy {
    public static let allowedMosGorSudHosts: Set<String> = ["mos-gorsud.ru", "www.mos-gorsud.ru"]

    public static func isAllowedMosGorSud(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else {
            return false
        }
        return allowedMosGorSudHosts.contains(host)
    }

    public static func safeMosGorSudURL(_ url: URL) -> URL? {
        guard isAllowedMosGorSud(url) else { return nil }
        return ActFileLoader.sanitizedURL(url)
    }
}

private enum DOCXPreflight {
    private static let localHeader: UInt32 = 0x04034B50
    private static let centralDirectoryHeader: UInt32 = 0x02014B50
    private static let endOfCentralDirectory: UInt32 = 0x06054B50
    private static let zip64Locator: UInt32 = 0x07064B50
    private static let zip64Extra: UInt16 = 0x0001
    private static let encryptedFlags: UInt16 = 0x0001 | 0x0040 | 0x2000

    static func validate(_ data: Data, limits: ActFileLoader.Limits) throws {
        guard let eocd = findEndOfCentralDirectory(in: data) else {
            throw PublishedActFileError.unsafeDOCX
        }
        if eocd >= 20, try uint32(data, at: eocd - 20) == zip64Locator {
            throw PublishedActFileError.unsafeDOCX
        }
        let disk = try uint16(data, at: eocd + 4)
        let centralDisk = try uint16(data, at: eocd + 6)
        let entriesOnDisk = try uint16(data, at: eocd + 8)
        let entryCount = try uint16(data, at: eocd + 10)
        let centralSize = try uint32(data, at: eocd + 12)
        let centralOffset = try uint32(data, at: eocd + 16)
        let commentLength = try uint16(data, at: eocd + 20)

        guard disk == 0, centralDisk == 0, entriesOnDisk == entryCount,
              entryCount != .max, centralSize != .max, centralOffset != .max,
              Int(entryCount) <= limits.maxDOCXEntries,
              eocd + 22 + Int(commentLength) == data.count else {
            throw PublishedActFileError.unsafeDOCX
        }
        let centralStart = Int(centralOffset)
        let centralEnd = try checkedEnd(centralStart, Int(centralSize), in: data)
        guard centralEnd == eocd else { throw PublishedActFileError.unsafeDOCX }

        var cursor = centralStart
        var names = Set<String>()
        var localOffsets = Set<Int>()
        var localRanges: [Range<Int>] = []
        var totalUncompressed: UInt64 = 0
        for _ in 0..<Int(entryCount) {
            guard try uint32(data, at: cursor) == centralDirectoryHeader else {
                throw PublishedActFileError.unsafeDOCX
            }
            try requireRange(cursor, 46, in: data)
            let versionNeeded = try uint16(data, at: cursor + 6)
            let flags = try uint16(data, at: cursor + 8)
            let method = try uint16(data, at: cursor + 10)
            let crc32 = try uint32(data, at: cursor + 16)
            let compressed = try uint32(data, at: cursor + 20)
            let uncompressed = try uint32(data, at: cursor + 24)
            let nameLength = Int(try uint16(data, at: cursor + 28))
            let extraLength = Int(try uint16(data, at: cursor + 30))
            let commentLength = Int(try uint16(data, at: cursor + 32))
            let diskStart = try uint16(data, at: cursor + 34)
            let localOffset = try uint32(data, at: cursor + 42)
            let variableStart = cursor + 46
            let variableLength = try checkedSum(nameLength, extraLength, commentLength)
            let next = try checkedEnd(variableStart, variableLength, in: data)
            guard next <= centralEnd, versionNeeded < 45, flags & encryptedFlags == 0, diskStart == 0,
                  method == 0 || method == 8,
                  compressed != .max, uncompressed != .max, localOffset != .max else {
                throw PublishedActFileError.unsafeDOCX
            }

            let nameData = data.subdata(in: variableStart..<(variableStart + nameLength))
            guard let name = String(data: nameData, encoding: .utf8), isSafePath(name),
                  names.insert(name).inserted else {
                throw PublishedActFileError.unsafeDOCX
            }
            if try hasZip64Extra(data, offset: variableStart + nameLength, length: extraLength) {
                throw PublishedActFileError.unsafeDOCX
            }

            let compressed64 = UInt64(compressed)
            let uncompressed64 = UInt64(uncompressed)
            if uncompressed64 > 0 {
                guard compressed64 > 0,
                      isSafeCompressionRatio(
                        uncompressed64, compressed64,
                        limit: UInt64(limits.maxDOCXCompressionRatio)) else {
                    throw PublishedActFileError.unsafeDOCX
                }
            }
            let (nextTotal, overflow) = totalUncompressed.addingReportingOverflow(uncompressed64)
            guard !overflow, nextTotal <= UInt64(limits.maxDOCXUncompressedBytes) else {
                throw PublishedActFileError.unsafeDOCX
            }
            totalUncompressed = nextTotal

            let localOffsetValue = Int(localOffset)
            guard localOffsetValue < centralStart, localOffsets.insert(localOffsetValue).inserted else {
                throw PublishedActFileError.unsafeDOCX
            }
            let localRange = try validateLocalEntry(
                data, offset: localOffsetValue, centralStart: centralStart, nameData: nameData,
                flags: flags, method: method, compressedSize: Int(compressed),
                uncompressedSize: Int(uncompressed), crc32: crc32)
            guard !localRanges.contains(where: { $0.overlaps(localRange) }) else {
                throw PublishedActFileError.unsafeDOCX
            }
            localRanges.append(localRange)
            cursor = next
        }
        guard cursor == centralEnd,
              names.contains("[Content_Types].xml"), names.contains("_rels/.rels"),
              names.contains("word/document.xml") else {
            throw PublishedActFileError.unsafeDOCX
        }
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowerBound = max(0, data.count - (65_535 + 22))
        var cursor = data.count - 22
        while true {
            if (try? uint32(data, at: cursor)) == endOfCentralDirectory,
               let commentLength = try? uint16(data, at: cursor + 20),
               cursor + 22 + Int(commentLength) == data.count {
                return cursor
            }
            guard cursor > lowerBound else { return nil }
            cursor -= 1
        }
    }

    private static func validateLocalEntry(_ data: Data, offset: Int, centralStart: Int,
                                           nameData: Data, flags: UInt16, method: UInt16,
                                           compressedSize: Int, uncompressedSize: Int,
                                           crc32: UInt32) throws -> Range<Int> {
        try requireRange(offset, 30, in: data)
        let localVersion = try uint16(data, at: offset + 4)
        let localFlags = try uint16(data, at: offset + 6)
        let localMethod = try uint16(data, at: offset + 8)
        let localCRC32 = try uint32(data, at: offset + 14)
        let localCompressedSize = try uint32(data, at: offset + 18)
        let localUncompressedSize = try uint32(data, at: offset + 22)
        guard try uint32(data, at: offset) == localHeader,
              localVersion < 45, localFlags & encryptedFlags == 0,
              localMethod == method, localFlags == flags else {
            throw PublishedActFileError.unsafeDOCX
        }
        let nameLength = Int(try uint16(data, at: offset + 26))
        let extraLength = Int(try uint16(data, at: offset + 28))
        let nameStart = offset + 30
        let extraStart = try checkedEnd(nameStart, nameLength, in: data)
        let dataStart = try checkedEnd(extraStart, extraLength, in: data)
        guard data.subdata(in: nameStart..<extraStart) == nameData,
              !(try hasZip64Extra(data, offset: extraStart, length: extraLength)) else {
            throw PublishedActFileError.unsafeDOCX
        }
        if flags & 0x0008 == 0 {
            guard localCRC32 == crc32,
                  localCompressedSize == UInt32(compressedSize),
                  localUncompressedSize == UInt32(uncompressedSize) else {
                throw PublishedActFileError.unsafeDOCX
            }
        }
        let dataEnd = try checkedEnd(dataStart, compressedSize, in: data)
        guard dataEnd <= centralStart else { throw PublishedActFileError.unsafeDOCX }
        guard flags & 0x0008 != 0 else { return offset..<dataEnd }

        var descriptor = dataEnd
        if try uint32(data, at: descriptor) == 0x08074B50 { descriptor += 4 }
        try requireRange(descriptor, 12, in: data)
        guard try uint32(data, at: descriptor) == crc32,
              try uint32(data, at: descriptor + 4) == UInt32(compressedSize),
              try uint32(data, at: descriptor + 8) == UInt32(uncompressedSize) else {
            throw PublishedActFileError.unsafeDOCX
        }
        let descriptorEnd = descriptor + 12
        guard descriptorEnd <= centralStart else { throw PublishedActFileError.unsafeDOCX }
        return offset..<descriptorEnd
    }

    private static func hasZip64Extra(_ data: Data, offset: Int, length: Int) throws -> Bool {
        let end = try checkedEnd(offset, length, in: data)
        var cursor = offset
        while cursor < end {
            try requireRange(cursor, 4, in: data)
            let identifier = try uint16(data, at: cursor)
            let fieldLength = Int(try uint16(data, at: cursor + 2))
            cursor = try checkedEnd(cursor + 4, fieldLength, in: data)
            guard cursor <= end else { throw PublishedActFileError.unsafeDOCX }
            if identifier == zip64Extra { return true }
        }
        guard cursor == end else { throw PublishedActFileError.unsafeDOCX }
        return false
    }

    private static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.unicodeScalars.contains(where: { $0.value == 0 })
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    private static func isSafeCompressionRatio(_ uncompressed: UInt64, _ compressed: UInt64,
                                               limit: UInt64) -> Bool {
        let quotient = uncompressed / compressed
        let remainder = uncompressed % compressed
        return quotient < limit || (quotient == limit && remainder == 0)
    }

    private static func uint16(_ data: Data, at offset: Int) throws -> UInt16 {
        try requireRange(offset, 2, in: data)
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
        try requireRange(offset, 4, in: data)
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func requireRange(_ offset: Int, _ length: Int, in data: Data) throws {
        _ = try checkedEnd(offset, length, in: data)
    }

    private static func checkedEnd(_ offset: Int, _ length: Int, in data: Data) throws -> Int {
        guard offset >= 0, length >= 0 else { throw PublishedActFileError.unsafeDOCX }
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow, end <= data.count else { throw PublishedActFileError.unsafeDOCX }
        return end
    }

    private static func checkedSum(_ values: Int...) throws -> Int {
        try values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw PublishedActFileError.unsafeDOCX }
            return sum
        }
    }
}
