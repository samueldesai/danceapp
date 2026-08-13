//
//  ZipArchive.swift
//  Dance Player
//
//  Minimal in-process ZIP reader/writer, used for `.dbdj` project files and for reading
//  `.xlsx` workbooks. Deliberately does not shell out to /usr/bin/zip or /usr/bin/unzip:
//  the app is sandboxed, and a child process doesn't inherit the powerbox grant for a
//  user-selected file, so those calls fail for exactly the files we care about.
//

import Foundation
import Compression

enum ZipArchiveError: LocalizedError {
    case unreadable
    case malformed
    case unsupportedZip64
    case entryTooLarge(String)
    case notWritable(URL)

    var errorDescription: String? {
        switch self {
        case .notWritable(let url):
            return "Couldn't create \(url.lastPathComponent) in "
                + "\(url.deletingLastPathComponent().path) — the app may not have permission "
                + "to write there."
        case .unreadable:
            return "The file couldn't be read."
        case .malformed:
            return "The file isn't a valid archive."
        case .unsupportedZip64:
            return "This archive uses ZIP64, which isn't supported."
        case .entryTooLarge(let name):
            return "\"\(name)\" is larger than the 4 GB limit for this archive format."
        }
    }
}

struct ZipArchive {

    // MARK: - Writing

    /// Zips the *contents* of `directoryURL` (so the archive has no redundant top-level
    /// folder) into a new file at `destinationURL`.
    static func zip(contentsOf directoryURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        // Report a failed create here rather than letting it fall through to FileHandle,
        // which reports the same problem as "the file doesn't exist" and hides the cause.
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw ZipArchiveError.notWritable(destinationURL)
        }

        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        var centralDirectory = Data()
        var entryCount = 0
        var offset: UInt32 = 0

        for fileURL in try filesToArchive(in: directoryURL) {
            let relativePath = fileURL.path
                .replacingOccurrences(of: directoryURL.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else { continue }

            let contents = try Data(contentsOf: fileURL)
            guard contents.count <= UInt32.max else {
                throw ZipArchiveError.entryTooLarge(relativePath)
            }

            // Audio is already compressed, so deflate usually can't beat storing it —
            // whichever is smaller wins.
            let deflated = deflate(contents)
            let useDeflate = deflated != nil && deflated!.count < contents.count
            let payload = useDeflate ? deflated! : contents

            let nameBytes = Array(relativePath.utf8)
            let crc = crc32(contents)
            let modified = dosDateTime(for: fileURL)

            var localHeader = Data()
            localHeader.append(uint32: 0x04034b50)
            localHeader.append(uint16: 20)                       // version needed
            localHeader.append(uint16: 0)                        // flags
            localHeader.append(uint16: useDeflate ? 8 : 0)       // method
            localHeader.append(uint16: modified.time)
            localHeader.append(uint16: modified.date)
            localHeader.append(uint32: crc)
            localHeader.append(uint32: UInt32(payload.count))
            localHeader.append(uint32: UInt32(contents.count))
            localHeader.append(uint16: UInt16(nameBytes.count))
            localHeader.append(uint16: 0)                        // extra length
            localHeader.append(contentsOf: nameBytes)

            handle.write(localHeader)
            handle.write(payload)

            var centralEntry = Data()
            centralEntry.append(uint32: 0x02014b50)
            centralEntry.append(uint16: 20)                      // version made by
            centralEntry.append(uint16: 20)                      // version needed
            centralEntry.append(uint16: 0)                       // flags
            centralEntry.append(uint16: useDeflate ? 8 : 0)
            centralEntry.append(uint16: modified.time)
            centralEntry.append(uint16: modified.date)
            centralEntry.append(uint32: crc)
            centralEntry.append(uint32: UInt32(payload.count))
            centralEntry.append(uint32: UInt32(contents.count))
            centralEntry.append(uint16: UInt16(nameBytes.count))
            centralEntry.append(uint16: 0)                       // extra length
            centralEntry.append(uint16: 0)                       // comment length
            centralEntry.append(uint16: 0)                       // disk number start
            centralEntry.append(uint16: 0)                       // internal attributes
            centralEntry.append(uint32: 0)                       // external attributes
            centralEntry.append(uint32: offset)
            centralEntry.append(contentsOf: nameBytes)
            centralDirectory.append(centralEntry)

            entryCount += 1
            let entrySize = localHeader.count + payload.count
            guard offset.addingReportingOverflow(UInt32(entrySize)).overflow == false else {
                throw ZipArchiveError.entryTooLarge(relativePath)
            }
            offset += UInt32(entrySize)
        }

        let centralDirectoryOffset = offset
        handle.write(centralDirectory)

        var end = Data()
        end.append(uint32: 0x06054b50)
        end.append(uint16: 0)                                    // this disk
        end.append(uint16: 0)                                    // disk with central directory
        end.append(uint16: UInt16(entryCount))
        end.append(uint16: UInt16(entryCount))
        end.append(uint32: UInt32(centralDirectory.count))
        end.append(uint32: centralDirectoryOffset)
        end.append(uint16: 0)                                    // comment length
        handle.write(end)
    }

    /// Depth-first list of regular files, skipping directories (readers recreate those) and
    /// Finder metadata that would just be noise inside a project file.
    private static func filesToArchive(in directoryURL: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw ZipArchiveError.unreadable
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                results.append(url)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    // MARK: - Reading

    /// Expands every entry into `directoryURL`, creating intermediate folders as needed.
    static func unzip(_ archiveURL: URL, to directoryURL: URL) throws {
        let data = try readArchive(at: archiveURL)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        for entry in try entries(in: data) {
            // Refuse paths that would escape the destination ("../" traversal).
            let components = entry.name.split(separator: "/").map(String.init)
            guard !components.contains(".."), !components.isEmpty else { continue }
            guard !entry.name.hasSuffix("/") else { continue }

            let destinationURL = components.reduce(directoryURL) { $0.appendingPathComponent($1) }
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let contents = payload(of: entry, in: data) else { throw ZipArchiveError.malformed }
            try contents.write(to: destinationURL, options: .atomic)
        }
    }

    /// Reads a single entry by name — used for `.xlsx`, where only two members matter.
    static func entryData(in archiveURL: URL, named entryName: String) -> Data? {
        guard let data = try? readArchive(at: archiveURL),
              let entry = (try? entries(in: data))?.first(where: { $0.name == entryName })
        else { return nil }
        return payload(of: entry, in: data)
    }

    private static func readArchive(at url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ZipArchiveError.unreadable
        }
        return data
    }

    private struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static func entries(in data: Data) throws -> [Entry] {
        // The end-of-central-directory record sits at the tail, after an optional comment,
        // so scan backwards for its signature.
        let minimumEnd = 22
        guard data.count >= minimumEnd else { throw ZipArchiveError.malformed }

        var endOffset: Int? = nil
        let searchFloor = max(0, data.count - 65_557)
        var cursor = data.count - minimumEnd
        while cursor >= searchFloor {
            if data.uint32(at: cursor) == 0x06054b50 {
                endOffset = cursor
                break
            }
            cursor -= 1
        }
        guard let end = endOffset else { throw ZipArchiveError.malformed }

        let entryCount = Int(data.uint16(at: end + 10))
        let directoryOffset = Int(data.uint32(at: end + 16))
        if directoryOffset == 0xFFFF_FFFF || entryCount == 0xFFFF {
            throw ZipArchiveError.unsupportedZip64
        }

        var results: [Entry] = []
        var offset = directoryOffset
        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, data.uint32(at: offset) == 0x02014b50 else {
                throw ZipArchiveError.malformed
            }
            let method = data.uint16(at: offset + 10)
            let compressedSize = Int(data.uint32(at: offset + 20))
            let uncompressedSize = Int(data.uint32(at: offset + 24))
            let nameLength = Int(data.uint16(at: offset + 28))
            let extraLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            let localOffset = Int(data.uint32(at: offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { throw ZipArchiveError.malformed }
            let name = String(decoding: data.subdata(in: nameStart..<(nameStart + nameLength)))

            results.append(
                Entry(
                    name: name,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localOffset
                )
            )
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return results
    }

    private static func payload(of entry: Entry, in data: Data) -> Data? {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.uint32(at: header) == 0x04034b50 else { return nil }

        let nameLength = Int(data.uint16(at: header + 26))
        let extraLength = Int(data.uint16(at: header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { return nil }

        let raw = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            return raw
        case 8:
            return inflate(raw, expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    // MARK: - Compression

    /// Apple's COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is exactly what ZIP
    /// method 8 stores. Returns nil when the result wouldn't be smaller than the input.
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        var destination = Data(count: data.count)
        let written = destination.withUnsafeMutableBytes { destinationBuffer in
            data.withUnsafeBytes { sourceBuffer in
                compression_encode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return destination.prefix(written)
    }

    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var destination = Data(count: expectedSize)
        let written = destination.withUnsafeMutableBytes { destinationBuffer in
            data.withUnsafeBytes { sourceBuffer in
                compression_decode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { return nil }
        return destination
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1 == 1) ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var result: UInt32 = 0xFFFF_FFFF
        for byte in data {
            result = crcTable[Int((result ^ UInt32(byte)) & 0xFF)] ^ (result >> 8)
        }
        return result ^ 0xFFFF_FFFF
    }

    private static func dosDateTime(for url: URL) -> (date: UInt16, time: UInt16) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: modified
        )
        let year = max(1980, parts.year ?? 1980) - 1980
        let date = UInt16((year << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1))
        let time = UInt16((((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5) | ((parts.second ?? 0) / 2)))
        return (date, time)
    }
}

// MARK: - Byte helpers

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    func uint16(at offset: Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset + 3 < count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}

private extension String {
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
