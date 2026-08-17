import Compression
import Foundation

/// A minimal, read-only ZIP reader — just enough to pull named files out of an
/// Office package.
///
/// `.docx` and `.odt` are ZIP containers, and macOS has no public ZIP API. This
/// reads the central directory for the entry table and inflates entries with
/// `libcompression`, whose `COMPRESSION_ZLIB` is the raw DEFLATE stream ZIP
/// stores. Nothing here writes, and nothing decompresses until asked, so
/// listing an archive costs a scan of its directory and no more.
struct ZipArchive {
    struct Entry {
        let name: String
        let isCompressed: Bool
        let compressedSize: Int
        let uncompressedSize: Int
        let headerOffset: Int
    }

    private let data: Data
    let entries: [Entry]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        self.data = data
        guard let directoryStart = Self.centralDirectoryOffset(in: data) else { return nil }
        entries = Self.readCentralDirectory(in: data, from: directoryStart)
        guard !entries.isEmpty else { return nil }
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    func contents(of entry: Entry) -> Data? {
        // Name and extra lengths in the local header can differ from the ones in
        // the central directory, so re-read them here to find the data.
        let header = entry.headerOffset
        guard header + 30 <= data.count,
              u32(header) == 0x0403_4B50
        else { return nil }

        let nameLength = Int(u16(header + 26))
        let extraLength = Int(u16(header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= data.count else { return nil }

        let payload = data.subdata(in: start ..< end)
        guard entry.isCompressed else { return payload }
        return Self.inflate(payload, capacity: entry.uncompressedSize)
    }

    func contents(named name: String) -> Data? {
        entry(named: name).flatMap(contents)
    }

    // MARK: - Directory parsing

    private static func centralDirectoryOffset(in data: Data) -> Int? {
        // The end-of-central-directory record sits at the tail, after at most a
        // 64 KB comment.
        let window = min(data.count, 65_557)
        guard window >= 22 else { return nil }
        let lowest = data.count - window

        var index = data.count - 22
        while index >= lowest {
            if read32(data, index) == 0x0605_4B50 {
                return Int(read32(data, index + 16))
            }
            index -= 1
        }
        return nil
    }

    private static func readCentralDirectory(in data: Data, from start: Int) -> [Entry] {
        var entries: [Entry] = []
        var index = start

        while index + 46 <= data.count, read32(data, index) == 0x0201_4B50 {
            let method = read16(data, index + 10)
            let compressed = Int(read32(data, index + 20))
            let uncompressed = Int(read32(data, index + 24))
            let nameLength = Int(read16(data, index + 28))
            let extraLength = Int(read16(data, index + 30))
            let commentLength = Int(read16(data, index + 32))
            let headerOffset = Int(read32(data, index + 42))

            let nameStart = index + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(
                data: data.subdata(in: nameStart ..< nameStart + nameLength),
                encoding: .utf8
            )

            if let name {
                entries.append(
                    Entry(
                        name: name,
                        isCompressed: method == 8,
                        compressedSize: compressed,
                        uncompressedSize: uncompressed,
                        headerOffset: headerOffset
                    )
                )
            }
            index = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: - Inflate

    private static func inflate(_ source: Data, capacity: Int) -> Data? {
        guard capacity > 0, !source.isEmpty else { return Data() }

        var destination = Data(count: capacity)
        let written = destination.withUnsafeMutableBytes { output -> Int in
            source.withUnsafeBytes { input -> Int in
                guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress,
                      let inputBase = input.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    outputBase, capacity,
                    inputBase, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }
        return destination.prefix(written)
    }

    // MARK: - Little-endian reads

    private func u16(_ offset: Int) -> UInt16 { Self.read16(data, offset) }
    private func u32(_ offset: Int) -> UInt32 { Self.read32(data, offset) }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
