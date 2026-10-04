import Compression
import Foundation

/// Builds a ZIP archive in memory — the writing half of `ZipArchive`.
///
/// Every Office document is a ZIP package, and macOS has no public API for
/// writing one any more than for reading one. The format itself is small: a
/// local header and the bytes for each entry, then a central directory that
/// lists them all again, then a record saying where that directory starts.
///
/// Entries are compressed with `libcompression`, whose `COMPRESSION_ZLIB`
/// encoder produces exactly the raw DEFLATE stream ZIP stores — the same
/// pairing `ZipArchive` reads with. Anything that doesn't shrink is stored as
/// it is, which is also what happens to pictures: a JPEG or PNG is already
/// compressed, and running DEFLATE over it again only costs time.
struct ZipWriter {
    enum WriteError: LocalizedError {
        case tooLarge

        var errorDescription: String? { "The document is too large to save as a single file." }
    }

    private var body = Data()
    private var directory = Data()
    private var entryCount = 0
    private let stamp = DOSTimestamp(Date())

    /// Adds a file. `compress` is a request, not a promise — data that DEFLATE
    /// can't make smaller is stored instead.
    mutating func add(_ name: String, _ contents: Data, compress: Bool = true) throws {
        let nameBytes = Data(name.utf8)
        let checksum = CRC32.checksum(contents)
        let deflated = compress ? Self.deflate(contents) : nil
        let payload = deflated ?? contents
        let method: UInt16 = deflated == nil ? 0 : 8
        let offset = body.count

        guard body.count + payload.count + nameBytes.count + 30 < Int(UInt32.max),
              entryCount < Int(UInt16.max) - 1
        else { throw WriteError.tooLarge }

        // Local file header.
        body.appendLE(UInt32(0x0403_4B50))
        body.appendLE(UInt16(20)) // version needed to extract: 2.0, for DEFLATE
        body.appendLE(UInt16(0x0800)) // bit 11: the name is UTF-8
        body.appendLE(method)
        body.appendLE(stamp.time)
        body.appendLE(stamp.date)
        body.appendLE(checksum)
        body.appendLE(UInt32(payload.count))
        body.appendLE(UInt32(contents.count))
        body.appendLE(UInt16(nameBytes.count))
        body.appendLE(UInt16(0)) // extra field length
        body.append(nameBytes)
        body.append(payload)

        // The same entry again, for the central directory.
        directory.appendLE(UInt32(0x0201_4B50))
        directory.appendLE(UInt16(20)) // version made by
        directory.appendLE(UInt16(20)) // version needed to extract
        directory.appendLE(UInt16(0x0800))
        directory.appendLE(method)
        directory.appendLE(stamp.time)
        directory.appendLE(stamp.date)
        directory.appendLE(checksum)
        directory.appendLE(UInt32(payload.count))
        directory.appendLE(UInt32(contents.count))
        directory.appendLE(UInt16(nameBytes.count))
        directory.appendLE(UInt16(0)) // extra field length
        directory.appendLE(UInt16(0)) // comment length
        directory.appendLE(UInt16(0)) // disk number
        directory.appendLE(UInt16(0)) // internal attributes
        directory.appendLE(UInt32(0)) // external attributes
        directory.appendLE(UInt32(offset))
        directory.append(nameBytes)

        entryCount += 1
    }

    mutating func add(_ name: String, _ text: String) throws {
        try add(name, Data(text.utf8))
    }

    /// The finished archive: the entries, the directory, and the end record.
    func finish() throws -> Data {
        guard body.count + directory.count + 22 < Int(UInt32.max) else { throw WriteError.tooLarge }

        var archive = body
        let directoryOffset = archive.count
        archive.append(directory)

        archive.appendLE(UInt32(0x0605_4B50))
        archive.appendLE(UInt16(0)) // this disk
        archive.appendLE(UInt16(0)) // disk where the directory starts
        archive.appendLE(UInt16(entryCount))
        archive.appendLE(UInt16(entryCount))
        archive.appendLE(UInt32(directory.count))
        archive.appendLE(UInt32(directoryOffset))
        archive.appendLE(UInt16(0)) // comment length
        return archive
    }

    // MARK: - Deflate

    private static func deflate(_ source: Data) -> Data? {
        // Small entries gain nothing worth the header bytes.
        guard source.count > 64 else { return nil }

        let capacity = source.count
        var destination = Data(count: capacity)
        let written = destination.withUnsafeMutableBytes { output -> Int in
            source.withUnsafeBytes { input -> Int in
                guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress,
                      let inputBase = input.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    outputBase, capacity,
                    inputBase, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        // Zero means it didn't fit in the space the original took up — so
        // compressing would have made it bigger, and storing is the better deal.
        guard written > 0, written < source.count else { return nil }
        return destination.prefix(written)
    }
}

// MARK: - CRC-32

/// The checksum ZIP records for every entry: CRC-32 with the reflected
/// polynomial `0xEDB88320`, the same one zlib, PNG, and Ethernet use.
enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { index in
        var value = UInt32(index)
        for _ in 0 ..< 8 {
            value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { raw in
                for byte in raw.bindMemory(to: UInt8.self) {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Helpers

/// ZIP's timestamps are MS-DOS ones: two-second resolution, local time, and
/// nothing before 1980.
private struct DOSTimestamp {
    let time: UInt16
    let date: UInt16

    init(_ date: Date) {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((parts.year ?? 1980) - 1980, 0)
        time = UInt16(((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5) | ((parts.second ?? 0) / 2))
        self.date = UInt16((year << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1))
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8(value >> 24))
    }
}
