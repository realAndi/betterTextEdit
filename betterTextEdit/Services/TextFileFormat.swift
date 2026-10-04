import Foundation

/// How a text file's characters are laid out on disk: the encoding, whether it
/// starts with a byte-order mark, and which line endings it uses.
///
/// None of this is visible in the editor, and all of it matters to whatever
/// reads the file next. A Windows batch file wants CRLF; a UTF-16 resource
/// file wants to stay UTF-16; a CSV exported from Excel often starts with a
/// UTF-8 BOM that Excel relies on to read it back. So a file is written back
/// exactly the way it was read — the editor only ever sees `\n` — unless the
/// user picks otherwise from the status bar.
struct TextFileFormat: Equatable {
    enum Encoding: String, CaseIterable, Identifiable {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
        case windowsLatin1
        case isoLatin1
        case macRoman

        var id: String { rawValue }

        var name: String {
            switch self {
            case .utf8: "UTF-8"
            case .utf16LittleEndian: "UTF-16 LE"
            case .utf16BigEndian: "UTF-16 BE"
            case .windowsLatin1: "Western (Windows 1252)"
            case .isoLatin1: "Western (ISO Latin 1)"
            case .macRoman: "Western (Mac OS Roman)"
            }
        }

        /// The short form the status bar shows.
        var label: String {
            switch self {
            case .utf8: "UTF-8"
            case .utf16LittleEndian: "UTF-16 LE"
            case .utf16BigEndian: "UTF-16 BE"
            case .windowsLatin1: "Windows 1252"
            case .isoLatin1: "Latin 1"
            case .macRoman: "Mac Roman"
            }
        }

        var foundation: String.Encoding {
            switch self {
            case .utf8: .utf8
            case .utf16LittleEndian: .utf16LittleEndian
            case .utf16BigEndian: .utf16BigEndian
            case .windowsLatin1: .windowsCP1252
            case .isoLatin1: .isoLatin1
            case .macRoman: .macOSRoman
            }
        }

        var byteOrderMark: [UInt8] {
            switch self {
            case .utf8: [0xEF, 0xBB, 0xBF]
            case .utf16LittleEndian: [0xFF, 0xFE]
            case .utf16BigEndian: [0xFE, 0xFF]
            default: []
            }
        }

        /// UTF-16 can't be read at all without knowing its byte order, so a
        /// UTF-16 file always gets its mark.
        var requiresByteOrderMark: Bool {
            self == .utf16LittleEndian || self == .utf16BigEndian
        }

        var isUnicode: Bool {
            byteOrderMark.isEmpty == false
        }
    }

    enum LineEnding: String, CaseIterable, Identifiable {
        case lf
        case crlf
        case cr

        var id: String { rawValue }

        var characters: String {
            switch self {
            case .lf: "\n"
            case .crlf: "\r\n"
            case .cr: "\r"
            }
        }

        var label: String {
            switch self {
            case .lf: "LF"
            case .crlf: "CRLF"
            case .cr: "CR"
            }
        }

        var name: String {
            switch self {
            case .lf: "macOS and Unix (LF)"
            case .crlf: "Windows (CRLF)"
            case .cr: "Classic Mac OS (CR)"
            }
        }
    }

    var encoding: Encoding = .utf8
    var byteOrderMark = false
    var lineEnding: LineEnding = .lf

    /// What a new document is written as.
    static let standard = TextFileFormat()

    var label: String {
        encoding.label + (byteOrderMark && !encoding.requiresByteOrderMark ? " with BOM" : "")
    }

    // MARK: - Reading

    enum DecodeError: Error {
        case notText
    }

    /// Works out a file's format and decodes it, with line endings normalised
    /// to `\n`.
    ///
    /// A byte-order mark is believed. Without one, UTF-8 is tried first — it's
    /// strict enough that anything which decodes as UTF-8 almost certainly is
    /// — then UTF-16 for files that are plainly two bytes to a character, and
    /// only then the single-byte Western encodings, which will decode anything
    /// and so are a last resort for data that already looks like text.
    /// Windows 1252 is preferred to ISO Latin 1 because it's what such files
    /// almost always are: the two agree everywhere except 0x80–0x9F, where
    /// Latin 1 has invisible control codes and Windows 1252 has curly quotes,
    /// dashes, and the euro sign.
    static func decode(_ data: Data, as forced: Encoding? = nil) throws -> (String, TextFileFormat) {
        var format = TextFileFormat()
        var body = data

        if let forced {
            format.encoding = forced
            if !forced.byteOrderMark.isEmpty, data.starts(with: forced.byteOrderMark) {
                format.byteOrderMark = true
                body = data.dropFirst(forced.byteOrderMark.count)
            }
        } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            format.encoding = .utf8
            format.byteOrderMark = true
            body = data.dropFirst(3)
        } else if data.starts(with: [0xFF, 0xFE]) {
            format.encoding = .utf16LittleEndian
            format.byteOrderMark = true
            body = data.dropFirst(2)
        } else if data.starts(with: [0xFE, 0xFF]) {
            format.encoding = .utf16BigEndian
            format.byteOrderMark = true
            body = data.dropFirst(2)
        } else if let order = utf16Order(of: data) {
            // Before UTF-8: ASCII with a NUL after every letter is, strictly,
            // valid UTF-8 too.
            format.encoding = order
        } else if String(data: data, encoding: .utf8) != nil {
            format.encoding = .utf8
        } else if looksLikeText(data) {
            format.encoding = .windowsLatin1
        } else {
            throw DecodeError.notText
        }

        guard var text = String(data: Data(body), encoding: format.encoding.foundation)
            // Windows 1252 leaves five bytes undefined; Latin 1 defines them all.
            ?? (format.encoding == .windowsLatin1 ? String(data: Data(body), encoding: .isoLatin1) : nil)
        else { throw DecodeError.notText }

        format.lineEnding = dominantLineEnding(in: text)
        // Bytes, not characters: Swift reads `\r\n` as one character, which
        // `contains("\r")` would never find.
        if text.utf8.contains(0x0D) {
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        return (text, format)
    }

    /// The line ending most lines use. Mixed files are written back with this
    /// one throughout, which is what every editor that normalises does.
    static func dominantLineEnding(in text: String) -> LineEnding {
        var crlf = 0, cr = 0, lf = 0
        var previous: UInt8 = 0
        var index = text.utf8.startIndex
        // Counting the first megabyte is plenty to know a file's habit.
        let limit = text.utf8.index(index, offsetBy: 1_048_576, limitedBy: text.utf8.endIndex) ?? text.utf8.endIndex
        while index < limit {
            let byte = text.utf8[index]
            if byte == 0x0A {
                if previous == 0x0D { crlf += 1; cr -= 1 } else { lf += 1 }
            } else if byte == 0x0D {
                cr += 1
            }
            previous = byte
            index = text.utf8.index(after: index)
        }
        if crlf > lf, crlf >= cr { return .crlf }
        if cr > lf, cr > crlf { return .cr }
        return .lf
    }

    /// UTF-16 without a byte-order mark is still recognisable: text in any
    /// Latin script has a zero in every other byte.
    private static func utf16Order(of data: Data) -> Encoding? {
        let sample = data.prefix(4096)
        guard sample.count >= 4, sample.count.isMultiple(of: 2) || data.count > 4096 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (offset, byte) in sample.enumerated() where byte == 0 {
            if offset.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        let pairs = sample.count / 2
        if oddZeros > pairs * 3 / 5, evenZeros < pairs / 10 { return .utf16LittleEndian }
        if evenZeros > pairs * 3 / 5, oddZeros < pairs / 10 { return .utf16BigEndian }
        return nil
    }

    /// A cheap binary sniff: NUL bytes, or a lot of control characters, mean
    /// this is not something anyone wants to see in a text editor.
    static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        guard !sample.isEmpty else { return true }

        var controls = 0
        for byte in sample {
            if byte == 0 { return false }
            if byte < 0x09 || (byte > 0x0D && byte < 0x20) { controls += 1 }
        }
        return Double(controls) / Double(sample.count) < 0.05
    }

    // MARK: - Writing

    enum EncodeError: LocalizedError {
        case unrepresentable(Encoding)

        var errorDescription: String? {
            switch self {
            case let .unrepresentable(encoding):
                "This text has characters that can’t be saved as \(encoding.name)."
            }
        }
    }

    /// The bytes to write for `text`, which uses `\n` throughout.
    func encode(_ text: String) throws -> Data {
        let lines = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.characters)
        guard let body = lines.data(using: encoding.foundation, allowLossyConversion: false) else {
            throw EncodeError.unrepresentable(encoding)
        }
        guard byteOrderMark || encoding.requiresByteOrderMark else { return body }
        return Data(encoding.byteOrderMark) + body
    }

    /// True when `text` can be written in this format without losing anything.
    func canEncode(_ text: String) -> Bool {
        encoding.isUnicode || text.data(using: encoding.foundation, allowLossyConversion: false) != nil
    }
}
