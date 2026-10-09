import Compression
import Foundation

/// A parsed view of a PDF file's object graph, built far enough to append to it.
///
/// PDFKit can read a document but not tell you where anything sits in the file: it hands
/// back pages and annotations, never object numbers or byte offsets. Appending an update
/// needs both, so this reads the cross-reference chain itself.
///
/// Only what an append needs is implemented. Encrypted documents and the handful of
/// legacy filters are refused rather than half-handled — `PDFHighlightStore` falls back to
/// PDFKit's whole-file write for those, which is slow but always correct.
struct PDFObjectFile {

    /// A PDF object. `stream` keeps its bytes as they sit in the file, still encoded: an
    /// append copies most objects through untouched, and re-encoding them would change
    /// bytes this writer has no business changing.
    indirect enum Object: Equatable {
        case null
        case boolean(Bool)
        case integer(Int)
        case real(Double)
        /// Decoded bytes. Literal and hex strings both land here; the writer re-emits them
        /// in literal form.
        case string([UInt8])
        case name(String)
        case array([Object])
        case dictionary([String: Object])
        case stream(dictionary: [String: Object], encoded: [UInt8])
        case reference(number: Int, generation: Int)

        var intValue: Int? {
            switch self {
            case let .integer(value): return value
            case let .real(value): return Int(value)
            default: return nil
            }
        }

        var doubleValue: Double? {
            switch self {
            case let .integer(value): return Double(value)
            case let .real(value): return value
            default: return nil
            }
        }

        var nameValue: String? {
            if case let .name(value) = self { return value }
            return nil
        }

        var arrayValue: [Object]? {
            if case let .array(value) = self { return value }
            return nil
        }

        /// A stream's dictionary reads like a dictionary, because every caller that wants
        /// `/Type` or `/Length` should not care which of the two it was handed.
        var dictionaryValue: [String: Object]? {
            switch self {
            case let .dictionary(value): return value
            case let .stream(dictionary, _): return dictionary
            default: return nil
            }
        }

        var referenceValue: (number: Int, generation: Int)? {
            if case let .reference(number, generation) = self { return (number, generation) }
            return nil
        }
    }

    /// Where an object's bytes are. A PDF 1.5 file can pack objects inside a stream, so
    /// "offset in the file" is only one of the two answers.
    enum Location: Equatable {
        case offset(Int)
        case inObjectStream(container: Int, index: Int)
    }

    enum Failure: Error {
        /// The document is encrypted. Appending would have to encrypt the new strings and
        /// streams with the document's key, which means implementing the security handler.
        case encrypted
        /// A filter this reader does not implement — LZW, JBIG2, a crypt filter — guards an
        /// object the append has to read.
        case unsupportedFilter(String)
        case malformed(String)
    }

    let bytes: [UInt8]
    /// Every object the cross-reference chain resolves, newest generation winning.
    private(set) var locations: [Int: Location] = [:]
    /// The trailer, with the newest section's keys taking precedence.
    private(set) var trailer: [String: Object] = [:]
    /// The byte offset of the cross-reference section the newest trailer was read from.
    /// An appended update chains back to it through `/Prev`.
    private(set) var startXref: Int = 0
    /// Whether the newest section is a cross-reference stream. An update writes whichever
    /// form the file already uses, so a reader that only understands one still resolves it.
    private(set) var usesCrossReferenceStream = false

    private var objectStreamCache: [Int: [Int: [UInt8]]] = [:]

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        try readCrossReferenceChain()
        if trailer["Encrypt"] != nil { throw Failure.encrypted }
    }

    init(contentsOf url: URL) throws {
        try self.init(bytes: [UInt8](Data(contentsOf: url)))
    }

    /// The highest object number the file uses, which is where new objects start counting.
    var size: Int {
        max(trailer["Size"]?.intValue ?? 0, (locations.keys.max() ?? 0) + 1)
    }

    // MARK: - Reading objects

    /// The object with this number, or `.null` if the chain does not resolve it.
    mutating func object(_ number: Int) throws -> Object {
        guard let location = locations[number] else { return .null }
        switch location {
        case let .offset(offset):
            var scanner = Scanner(bytes: bytes, index: offset)
            return try scanner.parseIndirectObject(expecting: number, in: &self)
        case let .inObjectStream(container, index):
            let contents = try objectStream(container)
            guard let body = contents[number] else { return .null }
            _ = index
            var scanner = Scanner(bytes: body, index: 0)
            return try scanner.parseObject(in: &self)
        }
    }

    /// Follows references until something else comes back. A `/Length` or a `/Annots` is as
    /// likely to be indirect as direct, and no caller wants to care which.
    mutating func resolve(_ object: Object?) throws -> Object {
        var current = object ?? .null
        var hops = 0
        while case let .reference(number, _) = current {
            hops += 1
            guard hops < 64 else { throw Failure.malformed("reference cycle") }
            current = try self.object(number)
        }
        return current
    }

    /// A stream's bytes with its filters undone.
    mutating func decoded(_ object: Object) throws -> [UInt8] {
        guard case let .stream(dictionary, encoded) = object else { return [] }
        var data = encoded
        let filters: [String]
        switch try resolve(dictionary["Filter"]) {
        case let .name(single): filters = [single]
        case let .array(list): filters = list.compactMap(\.nameValue)
        default: filters = []
        }
        var parameterList: [[String: Object]] = []
        switch try resolve(dictionary["DecodeParms"]) {
        case let .dictionary(single): parameterList = [single]
        case let .array(list):
            for entry in list {
                parameterList.append(try resolve(entry).dictionaryValue ?? [:])
            }
        default: parameterList = []
        }
        for (index, filter) in filters.enumerated() {
            let parameters = index < parameterList.count ? parameterList[index] : [:]
            switch filter {
            case "FlateDecode", "Fl":
                data = try Self.inflate(data)
                data = try applyPredictor(to: data, parameters: parameters)
            case "ASCIIHexDecode", "AHx":
                data = Self.decodeASCIIHex(data)
                data = try applyPredictor(to: data, parameters: parameters)
            default:
                throw Failure.unsupportedFilter(filter)
            }
        }
        return data
    }

    // MARK: - Page tree

    /// The object number of each page, in reading order.
    ///
    /// Walked over references rather than PDFKit's page list because an append has to name
    /// the page object it is rewriting, and PDFKit never exposes that number.
    mutating func pageObjectNumbers() throws -> [Int] {
        guard let root = trailer["Root"]?.referenceValue else {
            throw Failure.malformed("no document catalog")
        }
        let catalog = try object(root.number)
        guard let pages = catalog.dictionaryValue?["Pages"]?.referenceValue else {
            throw Failure.malformed("no page tree")
        }
        var numbers: [Int] = []
        var visited: Set<Int> = []
        try collectPages(from: pages.number, into: &numbers, visited: &visited)
        return numbers
    }

    private mutating func collectPages(from number: Int, into numbers: inout [Int],
                                       visited: inout Set<Int>) throws {
        guard !visited.contains(number) else { throw Failure.malformed("page tree cycle") }
        visited.insert(number)
        let node = try object(number)
        guard let dictionary = node.dictionaryValue else { return }
        let kind = try resolve(dictionary["Type"]).nameValue
        // A node with /Kids is an internal node whatever it calls itself: some producers
        // leave /Type off entirely, and a leaf is then the node that has no children.
        guard let kids = try resolve(dictionary["Kids"]).arrayValue, kind != "Page" else {
            numbers.append(number)
            return
        }
        for kid in kids {
            guard let reference = kid.referenceValue else { continue }
            try collectPages(from: reference.number, into: &numbers, visited: &visited)
        }
    }

    // MARK: - Cross-reference chain

    private mutating func readCrossReferenceChain() throws {
        guard let start = lastStartXref() else { throw Failure.malformed("no startxref") }
        startXref = start
        var offset: Int? = start
        var seen: Set<Int> = []
        var first = true
        while let current = offset {
            guard !seen.contains(current), current >= 0, current < bytes.count else { break }
            seen.insert(current)
            let section = try readCrossReferenceSection(at: current)
            if first {
                usesCrossReferenceStream = section.isStream
                first = false
            }
            // Older sections fill in only what newer ones left unsaid: the chain runs
            // newest first, and an update's whole point is to shadow what came before.
            for (number, location) in section.locations where locations[number] == nil {
                locations[number] = location
            }
            for (key, value) in section.trailer where trailer[key] == nil {
                trailer[key] = value
            }
            // A hybrid file keeps a second, stream-shaped section for readers that
            // understand it. Its entries are newer than anything further back the chain.
            if let hybrid = section.trailer["XRefStm"]?.intValue, !seen.contains(hybrid) {
                seen.insert(hybrid)
                if let extra = try? readCrossReferenceSection(at: hybrid) {
                    for (number, location) in extra.locations where locations[number] == nil {
                        locations[number] = location
                    }
                }
            }
            offset = section.trailer["Prev"]?.intValue
        }
        guard !locations.isEmpty else { throw Failure.malformed("empty cross-reference table") }
    }

    private struct Section {
        var locations: [Int: Location] = [:]
        var trailer: [String: Object] = [:]
        var isStream = false
    }

    private mutating func readCrossReferenceSection(at offset: Int) throws -> Section {
        var scanner = Scanner(bytes: bytes, index: offset)
        scanner.skipWhitespaceAndComments()
        if scanner.matches("xref") {
            return try readCrossReferenceTable(&scanner)
        }
        return try readCrossReferenceStream(at: offset)
    }

    private mutating func readCrossReferenceTable(_ scanner: inout Scanner) throws -> Section {
        var section = Section()
        scanner.skipWhitespaceAndComments()
        while !scanner.matches("trailer") {
            scanner.skipWhitespaceAndComments()
            guard let start = scanner.readInteger(), let count = scanner.readInteger() else {
                throw Failure.malformed("bad cross-reference subsection header")
            }
            guard count >= 0, count < 8_000_000 else {
                throw Failure.malformed("implausible cross-reference subsection")
            }
            for row in 0..<count {
                scanner.skipWhitespaceAndComments()
                guard let position = scanner.readInteger(), scanner.readInteger() != nil else {
                    throw Failure.malformed("bad cross-reference entry")
                }
                scanner.skipWhitespaceAndComments()
                let kind = scanner.readByte()
                // A free entry is a hole in the numbering, not an object.
                guard kind == UInt8(ascii: "n") else { continue }
                let number = start + row
                if section.locations[number] == nil {
                    section.locations[number] = .offset(position)
                }
            }
            scanner.skipWhitespaceAndComments()
        }
        section.trailer = try scanner.parseObject(in: &self).dictionaryValue ?? [:]
        return section
    }

    private mutating func readCrossReferenceStream(at offset: Int) throws -> Section {
        var scanner = Scanner(bytes: bytes, index: offset)
        let object = try scanner.parseIndirectObject(expecting: nil, in: &self)
        guard let dictionary = object.dictionaryValue else {
            throw Failure.malformed("cross-reference stream is not a stream")
        }
        let widths = try resolve(dictionary["W"]).arrayValue?.compactMap(\.intValue) ?? []
        guard widths.count >= 3 else { throw Failure.malformed("cross-reference stream has no /W") }
        let size = try resolve(dictionary["Size"]).intValue ?? 0
        var ranges: [(start: Int, count: Int)] = []
        if let index = try resolve(dictionary["Index"]).arrayValue?.compactMap(\.intValue),
           index.count >= 2 {
            for pair in stride(from: 0, to: index.count - 1, by: 2) {
                ranges.append((index[pair], index[pair + 1]))
            }
        } else {
            ranges = [(0, size)]
        }

        let data = try decoded(object)
        let rowWidth = widths.reduce(0, +)
        guard rowWidth > 0 else { throw Failure.malformed("zero-width cross-reference rows") }
        var section = Section(isStream: true)
        var cursor = 0
        for range in ranges {
            for row in 0..<range.count {
                guard cursor + rowWidth <= data.count else { break }
                var fields: [Int] = []
                for width in widths {
                    var value = 0
                    for _ in 0..<width {
                        value = value << 8 | Int(data[cursor])
                        cursor += 1
                    }
                    fields.append(value)
                }
                // A zero-width first field means "type 1", the default the spec gives.
                let kind = widths[0] == 0 ? 1 : fields[0]
                let number = range.start + row
                guard section.locations[number] == nil else { continue }
                switch kind {
                case 1: section.locations[number] = .offset(fields[1])
                case 2: section.locations[number] = .inObjectStream(container: fields[1],
                                                                    index: fields[2])
                default: break
                }
            }
        }
        section.trailer = dictionary
        return section
    }

    private func lastStartXref() -> Int? {
        let marker = Array("startxref".utf8)
        let window = max(0, bytes.count - 2048)
        var found: Int?
        var index = window
        while index + marker.count <= bytes.count {
            if Array(bytes[index..<(index + marker.count)]) == marker { found = index }
            index += 1
        }
        guard let position = found else { return nil }
        var scanner = Scanner(bytes: bytes, index: position + marker.count)
        scanner.skipWhitespaceAndComments()
        return scanner.readInteger()
    }

    // MARK: - Object streams

    private mutating func objectStream(_ number: Int) throws -> [Int: [UInt8]] {
        if let cached = objectStreamCache[number] { return cached }
        let container = try object(number)
        guard let dictionary = container.dictionaryValue else { return [:] }
        let data = try decoded(container)
        let count = try resolve(dictionary["N"]).intValue ?? 0
        let first = try resolve(dictionary["First"]).intValue ?? 0
        var scanner = Scanner(bytes: data, index: 0)
        var pairs: [(number: Int, offset: Int)] = []
        for _ in 0..<count {
            scanner.skipWhitespaceAndComments()
            guard let objectNumber = scanner.readInteger(),
                  let objectOffset = scanner.readInteger() else { break }
            pairs.append((objectNumber, objectOffset))
        }
        var contents: [Int: [UInt8]] = [:]
        for (position, pair) in pairs.enumerated() {
            let start = first + pair.offset
            let end = position + 1 < pairs.count ? first + pairs[position + 1].offset : data.count
            guard start >= 0, end <= data.count, start < end else { continue }
            contents[pair.number] = Array(data[start..<end])
        }
        objectStreamCache[number] = contents
        return contents
    }

    // MARK: - Filters

    private mutating func applyPredictor(to data: [UInt8],
                                         parameters: [String: Object]) throws -> [UInt8] {
        let predictor = try resolve(parameters["Predictor"]).intValue ?? 1
        guard predictor > 1 else { return data }
        let colors = try resolve(parameters["Colors"]).intValue ?? 1
        let bits = try resolve(parameters["BitsPerComponent"]).intValue ?? 8
        let columns = try resolve(parameters["Columns"]).intValue ?? 1
        guard predictor >= 10 else {
            throw Failure.unsupportedFilter("TIFF predictor \(predictor)")
        }
        let sampleWidth = max(1, colors * bits / 8)
        let rowWidth = (columns * colors * bits + 7) / 8
        guard rowWidth > 0 else { return data }
        var output: [UInt8] = []
        output.reserveCapacity(data.count)
        var previous = [UInt8](repeating: 0, count: rowWidth)
        var cursor = 0
        while cursor + 1 <= data.count - 1 {
            let tag = data[cursor]
            cursor += 1
            let end = min(cursor + rowWidth, data.count)
            var row = Array(data[cursor..<end])
            if row.count < rowWidth { row += [UInt8](repeating: 0, count: rowWidth - row.count) }
            cursor = end
            for index in 0..<rowWidth {
                let left = index >= sampleWidth ? Int(row[index - sampleWidth]) : 0
                let up = Int(previous[index])
                let upperLeft = index >= sampleWidth ? Int(previous[index - sampleWidth]) : 0
                let value: Int
                switch tag {
                case 0: value = Int(row[index])
                case 1: value = Int(row[index]) + left
                case 2: value = Int(row[index]) + up
                case 3: value = Int(row[index]) + (left + up) / 2
                case 4: value = Int(row[index]) + Self.paeth(left, up, upperLeft)
                default: throw Failure.malformed("unknown PNG predictor tag \(tag)")
                }
                row[index] = UInt8(value & 0xFF)
            }
            output += row
            previous = row
        }
        return output
    }

    private static func paeth(_ left: Int, _ up: Int, _ upperLeft: Int) -> Int {
        let estimate = left + up - upperLeft
        let distanceLeft = abs(estimate - left)
        let distanceUp = abs(estimate - up)
        let distanceUpperLeft = abs(estimate - upperLeft)
        if distanceLeft <= distanceUp, distanceLeft <= distanceUpperLeft { return left }
        if distanceUp <= distanceUpperLeft { return up }
        return upperLeft
    }

    /// `COMPRESSION_ZLIB` is Apple's name for a raw DEFLATE stream, while `/FlateDecode`
    /// data carries the two-byte zlib header and a trailing checksum, so the header is
    /// stepped over before decoding.
    static func inflate(_ data: [UInt8]) throws -> [UInt8] {
        guard !data.isEmpty else { return [] }
        var start = 0
        if data.count >= 2, data[0] & 0x0F == 8, (Int(data[0]) << 8 | Int(data[1])) % 31 == 0 {
            start = 2
        }
        let payload = Array(data[start...])
        guard !payload.isEmpty else { return [] }
        var capacity = max(payload.count * 8, 64 * 1024)
        for _ in 0..<8 {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = payload.withUnsafeBufferPointer { input -> Int in
                output.withUnsafeMutableBufferPointer { destination -> Int in
                    guard let source = input.baseAddress,
                          let target = destination.baseAddress else { return 0 }
                    return compression_decode_buffer(target, capacity, source, payload.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else { throw Failure.malformed("FlateDecode failed") }
            // A full buffer is ambiguous: the stream may have been truncated exactly at the
            // boundary, so it is decoded again with room to prove it was not.
            if written < capacity { return Array(output[0..<written]) }
            capacity *= 4
        }
        throw Failure.malformed("FlateDecode output did not fit")
    }

    private static func decodeASCIIHex(_ data: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var pending: UInt8?
        for byte in data {
            if byte == UInt8(ascii: ">") { break }
            guard let digit = Scanner.hexValue(byte) else { continue }
            if let high = pending {
                output.append(high << 4 | digit)
                pending = nil
            } else {
                pending = digit
            }
        }
        if let high = pending { output.append(high << 4) }
        return output
    }
}

extension PDFObjectFile {

    /// A cursor over PDF syntax. Deliberately a value type over a byte array: parsing runs
    /// inside object streams as readily as over the file, and both are just bytes.
    struct Scanner {
        let bytes: [UInt8]
        var index: Int

        init(bytes: [UInt8], index: Int) {
            self.bytes = bytes
            self.index = index
        }

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x00 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
                || byte == 0x20
        }

        static func isDelimiter(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
                 UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
                 UInt8(ascii: "/"), UInt8(ascii: "%"):
                return true
            default:
                return false
            }
        }

        static func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
            default: return nil
            }
        }

        mutating func skipWhitespaceAndComments() {
            while index < bytes.count {
                let byte = bytes[index]
                if Self.isWhitespace(byte) {
                    index += 1
                } else if byte == UInt8(ascii: "%") {
                    while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                        index += 1
                    }
                } else {
                    return
                }
            }
        }

        mutating func readByte() -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }

        /// Consumes `keyword` if it is next, leaving the cursor untouched otherwise.
        mutating func matches(_ keyword: String) -> Bool {
            skipWhitespaceAndComments()
            let wanted = Array(keyword.utf8)
            guard index + wanted.count <= bytes.count,
                  Array(bytes[index..<(index + wanted.count)]) == wanted else { return false }
            index += wanted.count
            return true
        }

        mutating func readInteger() -> Int? {
            skipWhitespaceAndComments()
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            let digitsStart = index
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"),
                  bytes[index] <= UInt8(ascii: "9") {
                index += 1
            }
            guard index > digitsStart else {
                index = start
                return nil
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            return Int(text)
        }

        mutating func parseIndirectObject(expecting number: Int?,
                                          in file: inout PDFObjectFile) throws -> Object {
            skipWhitespaceAndComments()
            guard let found = readInteger(), readInteger() != nil, matches("obj") else {
                throw Failure.malformed("expected an indirect object header")
            }
            if let number, found != number {
                throw Failure.malformed("object \(number) is not where the table says")
            }
            return try parseObject(in: &file)
        }

        mutating func parseObject(in file: inout PDFObjectFile) throws -> Object {
            skipWhitespaceAndComments()
            guard index < bytes.count else { return .null }
            switch bytes[index] {
            case UInt8(ascii: "/"):
                return .name(readName())
            case UInt8(ascii: "("):
                return .string(readLiteralString())
            case UInt8(ascii: "["):
                index += 1
                var items: [Object] = []
                while true {
                    skipWhitespaceAndComments()
                    guard index < bytes.count else { break }
                    if bytes[index] == UInt8(ascii: "]") {
                        index += 1
                        break
                    }
                    items.append(try parseObject(in: &file))
                }
                return .array(items)
            case UInt8(ascii: "<"):
                if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "<") {
                    return try parseDictionaryOrStream(in: &file)
                }
                return .string(readHexString())
            default:
                break
            }
            if matches("true") { return .boolean(true) }
            if matches("false") { return .boolean(false) }
            if matches("null") { return .null }
            return try parseNumberOrReference()
        }

        private mutating func parseDictionaryOrStream(in file: inout PDFObjectFile) throws -> Object {
            index += 2
            var dictionary: [String: Object] = [:]
            while true {
                skipWhitespaceAndComments()
                guard index < bytes.count else { break }
                if index + 1 < bytes.count, bytes[index] == UInt8(ascii: ">"),
                   bytes[index + 1] == UInt8(ascii: ">") {
                    index += 2
                    break
                }
                guard bytes[index] == UInt8(ascii: "/") else {
                    // A stray token inside a dictionary means the file is not shaped the way
                    // the table promised; stopping beats looping forever on it.
                    throw Failure.malformed("expected a key in a dictionary")
                }
                let key = readName()
                dictionary[key] = try parseObject(in: &file)
            }
            let save = index
            guard matches("stream") else {
                index = save
                return .dictionary(dictionary)
            }
            // The spec allows CRLF or LF after the keyword, and nothing else.
            if index < bytes.count, bytes[index] == 0x0D { index += 1 }
            if index < bytes.count, bytes[index] == 0x0A { index += 1 }
            let start = index
            let declared = try file.resolve(dictionary["Length"]).intValue
            var end = declared.map { start + $0 } ?? -1
            if end < start || end > bytes.count || !endstreamFollows(end) {
                // A wrong `/Length` is common enough in the wild that trusting it blindly
                // would make this reader fail on files every viewer opens.
                end = searchForEndstream(from: start) ?? bytes.count
            }
            index = end
            _ = matches("endstream")
            return .stream(dictionary: dictionary, encoded: Array(bytes[start..<min(end, bytes.count)]))
        }

        private func endstreamFollows(_ end: Int) -> Bool {
            var probe = Scanner(bytes: bytes, index: end)
            return probe.matches("endstream")
        }

        private func searchForEndstream(from start: Int) -> Int? {
            let marker = Array("endstream".utf8)
            var position = start
            while position + marker.count <= bytes.count {
                if bytes[position] == marker[0],
                   Array(bytes[position..<(position + marker.count)]) == marker {
                    var end = position
                    // The EOL that introduces `endstream` belongs to the keyword, not the data.
                    if end > start, bytes[end - 1] == 0x0A { end -= 1 }
                    if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                    return end
                }
                position += 1
            }
            return nil
        }

        private mutating func parseNumberOrReference() throws -> Object {
            skipWhitespaceAndComments()
            let start = index
            var sawDot = false
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                    index += 1
                } else if byte == UInt8(ascii: ".") , !sawDot {
                    sawDot = true
                    index += 1
                } else {
                    break
                }
            }
            guard index > start else {
                // Not a number at all. Step over the token so a malformed file cannot spin.
                index += 1
                return .null
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if sawDot { return .real(Double(text) ?? 0) }
            guard let value = Int(text) else { return .real(Double(text) ?? 0) }
            // `12 0 R` only reads as a reference with both numbers and the R in hand.
            let save = index
            var probe = self
            if let generation = probe.readInteger(), generation >= 0, probe.matches("R") {
                index = probe.index
                return .reference(number: value, generation: generation)
            }
            index = save
            return .integer(value)
        }

        private mutating func readName() -> String {
            index += 1
            var output: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                if Self.isWhitespace(byte) || Self.isDelimiter(byte) { break }
                if byte == UInt8(ascii: "#"), index + 2 < bytes.count,
                   let high = Self.hexValue(bytes[index + 1]),
                   let low = Self.hexValue(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
                output.append(byte)
                index += 1
            }
            return String(decoding: output, as: UTF8.self)
        }

        private mutating func readLiteralString() -> [UInt8] {
            index += 1
            var output: [UInt8] = []
            var depth = 1
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\\") {
                    guard index < bytes.count else { break }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "n"): output.append(0x0A)
                    case UInt8(ascii: "r"): output.append(0x0D)
                    case UInt8(ascii: "t"): output.append(0x09)
                    case UInt8(ascii: "b"): output.append(0x08)
                    case UInt8(ascii: "f"): output.append(0x0C)
                    case 0x0A: break
                    case 0x0D: if index < bytes.count, bytes[index] == 0x0A { index += 1 }
                    case UInt8(ascii: "0")...UInt8(ascii: "7"):
                        var value = Int(escape - UInt8(ascii: "0"))
                        for _ in 0..<2 {
                            guard index < bytes.count, bytes[index] >= UInt8(ascii: "0"),
                                  bytes[index] <= UInt8(ascii: "7") else { break }
                            value = value * 8 + Int(bytes[index] - UInt8(ascii: "0"))
                            index += 1
                        }
                        output.append(UInt8(value & 0xFF))
                    default: output.append(escape)
                    }
                    continue
                }
                if byte == UInt8(ascii: "(") { depth += 1 }
                if byte == UInt8(ascii: ")") {
                    depth -= 1
                    if depth == 0 { break }
                }
                output.append(byte)
            }
            return output
        }

        private mutating func readHexString() -> [UInt8] {
            index += 1
            var output: [UInt8] = []
            var pending: UInt8?
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: ">") { break }
                guard let digit = Self.hexValue(byte) else { continue }
                if let high = pending {
                    output.append(high << 4 | digit)
                    pending = nil
                } else {
                    pending = digit
                }
            }
            if let high = pending { output.append(high << 4) }
            return output
        }
    }
}
