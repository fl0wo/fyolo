import AppKit
import CoreGraphics
import Foundation

/// Writes marks into a PDF the way Preview does: by appending an update, never by
/// rewriting the book.
///
/// PDFKit's only save is `PDFDocument.write(to:)`, which re-serializes the whole document.
/// Measured on this repo's reading pile that costs about two and a half seconds on a
/// 300-page book and can nearly double the file, because the rewrite loses the original's
/// object streams and compression. Preview does not pay either price: it leaves every
/// existing byte alone and appends new objects, a fresh cross-reference section, and a
/// trailer chained back through `/Prev` — the incremental update of PDF 32000-1 §7.5.6.
/// Highlighting a page in Preview and diffing the result shows the original bytes
/// unchanged and roughly eighty kilobytes added.
///
/// This does the same. A save is proportional to the marks written rather than to the size
/// of the book, and because the base document is never re-encoded, a marked-up PDF still
/// opens in whatever produced it.
enum PDFIncrementalWriter {

    enum Failure: Error {
        /// The document cannot take an append — encrypted, or shaped in a way this writer
        /// will not guess at. The caller falls back to PDFKit's whole-file write.
        case unsupported(String)
        case io(String)
    }

    /// Appends `edits` to the document at `url`.
    ///
    /// The work happens on an APFS clone of the original, which costs nothing to make, and
    /// the clone is swapped in only once every byte is on disk. An interrupted save leaves
    /// the book exactly as it was.
    static func append(_ edits: PDFHighlightStore.Edits, to url: URL) throws
        -> PDFHighlightStore.SaveResult {
        guard !edits.isEmpty else { return PDFHighlightStore.SaveResult(written: true, unapplied: []) }

        var file: PDFObjectFile
        do {
            file = try PDFObjectFile(contentsOf: url)
        } catch let failure as PDFObjectFile.Failure {
            throw Failure.unsupported("\(failure)")
        }

        let pageNumbers = try pageNumbers(of: &file)
        var unapplied: [PDFHighlight] = []

        // Everything the append will add or shadow, keyed by object number. Built in full
        // before a single byte is written so a document that turns out to be unwritable
        // fails before it is touched.
        var emitted: [Int: PDFObjectFile.Object] = [:]
        var nextNumber = file.size

        func reserve() -> Int {
            defer { nextNumber += 1 }
            return nextNumber
        }

        let touchedPages = Set(edits.added.map(\.page) + edits.removed.map(\.page)
            + edits.recoloured.map(\.page))
        var changed = false

        for pageIndex in touchedPages.sorted() {
            guard pageIndex >= 0, pageIndex < pageNumbers.count else {
                unapplied += edits.added.filter { $0.page == pageIndex }
                continue
            }
            let pageNumber = pageNumbers[pageIndex]
            guard let pageDictionary = try file.object(pageNumber).dictionaryValue else {
                unapplied += edits.added.filter { $0.page == pageIndex }
                continue
            }

            let existing = try file.resolve(pageDictionary["Annots"]).arrayValue ?? []
            var annotations = existing

            let removals = edits.removed.filter { $0.page == pageIndex }
            if !removals.isEmpty {
                let survivors = try annotations.filter { entry in
                    guard let reference = entry.referenceValue else { return true }
                    let covered = try covers(reference.number, any: removals, in: &file)
                    return !covered
                }
                if survivors.count != annotations.count {
                    annotations = survivors
                    changed = true
                }
            }

            for mark in edits.recoloured where mark.page == pageIndex {
                for entry in annotations {
                    guard let reference = entry.referenceValue,
                          try covers(reference.number, any: [mark.placement], in: &file),
                          var dictionary = try file.object(reference.number).dictionaryValue
                    else { continue }
                    let ink = mark.ink.annotationColor
                    guard dictionary["C"] != colorObject(ink) else { continue }
                    dictionary["C"] = colorObject(ink)
                    // The stored appearance still paints the old ink. Regenerating it keeps
                    // the mark the same colour in readers that trust `/AP` over `/C`.
                    let quads = try quadPoints(of: dictionary, in: &file)
                    if let rect = try rectangle(of: dictionary, in: &file), !quads.isEmpty {
                        let stream = reserve()
                        emitted[stream] = appearanceStream(quads: quads, bounds: rect, ink: ink)
                        dictionary["AP"] = .dictionary(["N": .reference(number: stream, generation: 0)])
                    } else {
                        dictionary["AP"] = nil
                    }
                    emitted[reference.number] = .dictionary(dictionary)
                    changed = true
                }
            }

            // Which lines of this page are already under ink. Seeded from the annotations
            // the file carries and then kept up to date as this pass writes, because two
            // marks in one save can cover the same line and the second must not re-ink it —
            // the objects the first one wrote are not in the file yet to be found.
            var present = Set<PDFHighlight.Rect.Rounded>()
            for entry in annotations {
                guard let reference = entry.referenceValue else { continue }
                present.formUnion(try markedRectangles(of: reference.number, in: &file))
            }

            for mark in edits.added where mark.page == pageIndex {
                let quads = mark.rects.map(\.cgRect).filter { $0.width > 0 && $0.height > 0 }
                guard !quads.isEmpty else { continue }
                // Per rectangle, the way the old writer worked: a passage whose first line
                // is already marked still needs its remaining lines written.
                let fresh = quads.filter { !present.contains(PDFHighlight.Rect($0).rounded) }
                guard !fresh.isEmpty else { continue }
                present.formUnion(fresh.map { PDFHighlight.Rect($0).rounded })

                let bounds = fresh.dropFirst().reduce(fresh[0]) { $0.union($1) }
                let ink = mark.ink.annotationColor
                let stream = reserve()
                emitted[stream] = appearanceStream(quads: fresh, bounds: bounds, ink: ink)
                let annotation = reserve()
                emitted[annotation] = annotationObject(
                    quads: fresh, bounds: bounds, ink: ink, identifier: mark.id,
                    contents: mark.text, page: pageNumber, appearance: stream)
                annotations.append(.reference(number: annotation, generation: 0))
                changed = true
            }

            guard annotations != existing else { continue }
            // Rewriting the array object alone leaves the page untouched, which is both
            // fewer bytes and fewer chances to disturb a dictionary this writer only half
            // understands. Only a page whose `/Annots` is direct (or missing) needs the
            // page itself shadowed.
            if let reference = pageDictionary["Annots"]?.referenceValue {
                emitted[reference.number] = .array(annotations)
            } else {
                var updated = pageDictionary
                updated["Annots"] = .array(annotations)
                emitted[pageNumber] = .dictionary(updated)
            }
        }

        guard changed, !emitted.isEmpty else {
            return PDFHighlightStore.SaveResult(written: true, unapplied: unapplied)
        }

        let update = try serialize(emitted, appendingTo: file)
        try commit(update, to: url)
        return PDFHighlightStore.SaveResult(written: true, unapplied: unapplied)
    }

    // MARK: - Reading what is already there

    private static func pageNumbers(of file: inout PDFObjectFile) throws -> [Int] {
        do {
            return try file.pageObjectNumbers()
        } catch let failure as PDFObjectFile.Failure {
            throw Failure.unsupported("\(failure)")
        }
    }

    /// The rectangles a highlight annotation actually marks: one per quad, or its bounds
    /// when it carries no quads. This is the same grain the sidecar and the reader use, so
    /// a mark written here is the mark that reads back.
    private static func markedRectangles(of number: Int,
                                         in file: inout PDFObjectFile) throws
        -> Set<PDFHighlight.Rect.Rounded> {
        guard let dictionary = try file.object(number).dictionaryValue,
              try file.resolve(dictionary["Subtype"]).nameValue == "Highlight" else { return [] }
        let quads = try quadPoints(of: dictionary, in: &file)
        if !quads.isEmpty {
            return Set(quads.map { PDFHighlight.Rect($0).rounded })
        }
        guard let rect = try rectangle(of: dictionary, in: &file) else { return [] }
        return [PDFHighlight.Rect(rect).rounded]
    }

    private static func covers(_ number: Int, any placements: [PDFHighlight.Placement],
                               in file: inout PDFObjectFile) throws -> Bool {
        let marked = try markedRectangles(of: number, in: &file)
        guard !marked.isEmpty else { return false }
        for placement in placements where !marked.isDisjoint(with: Set(placement.rects)) {
            return true
        }
        return false
    }

    private static func rectangle(of dictionary: [String: PDFObjectFile.Object],
                                  in file: inout PDFObjectFile) throws -> CGRect? {
        guard let values = try file.resolve(dictionary["Rect"]).arrayValue?
            .compactMap(\.doubleValue), values.count == 4 else { return nil }
        return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]),
                      width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
    }

    /// `/QuadPoints` runs upper-left, upper-right, lower-left, lower-right per quad — the
    /// one place in PDF where the corners are not in ring order.
    private static func quadPoints(of dictionary: [String: PDFObjectFile.Object],
                                   in file: inout PDFObjectFile) throws -> [CGRect] {
        guard let values = try file.resolve(dictionary["QuadPoints"]).arrayValue?
            .compactMap(\.doubleValue), values.count >= 8 else { return [] }
        var rects: [CGRect] = []
        for start in stride(from: 0, to: values.count - 7, by: 8) {
            let xs = [values[start], values[start + 2], values[start + 4], values[start + 6]]
            let ys = [values[start + 1], values[start + 3], values[start + 5], values[start + 7]]
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { continue }
            rects.append(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }
        return rects
    }

    // MARK: - Building what goes in

    private static func annotationObject(quads: [CGRect], bounds: CGRect, ink: NSColor,
                                         identifier: UUID, contents: String, page: Int,
                                         appearance: Int) -> PDFObjectFile.Object {
        var points: [PDFObjectFile.Object] = []
        for quad in quads {
            for value in [quad.minX, quad.maxY, quad.maxX, quad.maxY,
                          quad.minX, quad.minY, quad.maxX, quad.minY] {
                points.append(.real(Double(value)))
            }
        }
        return .dictionary([
            "Type": .name("Annot"),
            "Subtype": .name("Highlight"),
            "Rect": rectObject(bounds),
            "QuadPoints": .array(points),
            "C": colorObject(ink),
            // Printable, and not hidden or locked: the flags Preview writes.
            "F": .integer(4),
            "Border": .array([.integer(0), .integer(0), .integer(0)]),
            // The mark's identity, so the several annotations of one passage regroup on
            // read. Preview puts a title here too, which is why reading it back is safe.
            "T": textObject(identifier.uuidString),
            "Contents": textObject(contents),
            "M": textObject(timestamp()),
            "P": .reference(number: page, generation: 0),
            "AP": .dictionary(["N": .reference(number: appearance, generation: 0)])
        ])
    }

    /// The appearance a viewer paints if it trusts `/AP` over `/C` — which Acrobat does,
    /// and which is why a highlight written without one shows up blank there.
    ///
    /// Multiply, so the words under the band stay black. The form is drawn in its own
    /// space with the origin at the mark's corner, and `/BBox` matching `/Rect`'s size maps
    /// it back onto the page one-to-one.
    private static func appearanceStream(quads: [CGRect], bounds: CGRect,
                                         ink: NSColor) -> PDFObjectFile.Object {
        let color = ink.usingColorSpace(.sRGB) ?? ink
        var content = "/GS gs\n"
        content += "\(number(color.redComponent)) \(number(color.greenComponent)) "
        content += "\(number(color.blueComponent)) rg\n"
        for quad in quads {
            let x = quad.minX - bounds.minX
            let y = quad.minY - bounds.minY
            content += "\(number(x)) \(number(y)) \(number(quad.width)) \(number(quad.height)) re\n"
        }
        content += "f\n"
        let body = Array(content.utf8)
        let dictionary: [String: PDFObjectFile.Object] = [
            "Type": .name("XObject"),
            "Subtype": .name("Form"),
            "FormType": .integer(1),
            "BBox": .array([.integer(0), .integer(0),
                            .real(Double(bounds.width)), .real(Double(bounds.height))]),
            "Resources": .dictionary([
                "ExtGState": .dictionary([
                    "GS": .dictionary([
                        "Type": .name("ExtGState"),
                        "BM": .name("Multiply"),
                        "ca": .integer(1),
                        "CA": .integer(1)
                    ])
                ])
            ]),
            "Length": .integer(body.count)
        ]
        return .stream(dictionary: dictionary, encoded: body)
    }

    private static func colorObject(_ color: NSColor) -> PDFObjectFile.Object {
        let sRGB = color.usingColorSpace(.sRGB) ?? color
        return .array([.real(Double(sRGB.redComponent)),
                       .real(Double(sRGB.greenComponent)),
                       .real(Double(sRGB.blueComponent))])
    }

    private static func rectObject(_ rect: CGRect) -> PDFObjectFile.Object {
        .array([.real(Double(rect.minX)), .real(Double(rect.minY)),
                .real(Double(rect.maxX)), .real(Double(rect.maxY))])
    }

    /// PDF text strings are Latin-1 unless they open with a byte-order mark, so anything
    /// outside it goes out as UTF-16BE — the same shape Preview writes its titles in.
    private static func textObject(_ text: String) -> PDFObjectFile.Object {
        if text.allSatisfy({ $0.isASCII }) {
            return .string(Array(text.utf8))
        }
        var bytes: [UInt8] = [0xFE, 0xFF]
        for scalar in Array(text.utf16) {
            bytes.append(UInt8(scalar >> 8))
            bytes.append(UInt8(scalar & 0xFF))
        }
        return .string(bytes)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "D:\(formatter.string(from: Date()))Z00'00'"
    }

    // MARK: - Emitting the update

    private static func serialize(_ emitted: [Int: PDFObjectFile.Object],
                                  appendingTo file: PDFObjectFile) throws -> [UInt8] {
        var output: [UInt8] = []
        // The original may not end with a newline, and an object header has to start on one.
        if file.bytes.last != 0x0A, file.bytes.last != 0x0D { output.append(0x0A) }

        let base = file.bytes.count
        var offsets: [Int: Int] = [:]
        for number in emitted.keys.sorted() {
            guard let object = emitted[number] else { continue }
            offsets[number] = base + output.count
            output += Array("\(number) 0 obj\n".utf8)
            output += write(object)
            output += Array("\nendobj\n".utf8)
        }

        var size = (emitted.keys.max() ?? 0) + 1
        size = max(size, file.size)

        if file.usesCrossReferenceStream {
            let number = size
            size += 1
            let start = base + output.count
            offsets[number] = start
            output += crossReferenceStream(number: number, offsets: offsets, size: size,
                                           previous: file.startXref, trailer: file.trailer)
            output += Array("startxref\n\(start)\n%%EOF\n".utf8)
        } else {
            let start = base + output.count
            output += crossReferenceTable(offsets: offsets)
            output += Array("trailer\n".utf8)
            output += write(.dictionary(updatedTrailer(file.trailer, size: size,
                                                       previous: file.startXref)))
            output += Array("\nstartxref\n\(start)\n%%EOF\n".utf8)
        }
        return output
    }

    /// Only what changed, in the contiguous runs the format asks for. Preview writes the
    /// whole table every time; there is no reason to, and on a long book the difference is
    /// most of the appended bytes.
    private static func crossReferenceTable(offsets: [Int: Int]) -> [UInt8] {
        var output = Array("xref\n".utf8)
        for run in runs(of: offsets.keys.sorted()) {
            output += Array("\(run.first!) \(run.count)\n".utf8)
            for number in run {
                let offset = String(format: "%010d", offsets[number] ?? 0)
                output += Array("\(offset) 00000 n \n".utf8)
            }
        }
        return output
    }

    /// The same information as a table, in the stream form a PDF 1.5 file uses. Written
    /// uncompressed: a filter would save a few hundred bytes and add a second thing that
    /// has to be exactly right.
    private static func crossReferenceStream(number: Int, offsets: [Int: Int], size: Int,
                                             previous: Int,
                                             trailer: [String: PDFObjectFile.Object]) -> [UInt8] {
        var index: [PDFObjectFile.Object] = []
        var rows: [UInt8] = []
        for run in runs(of: offsets.keys.sorted()) {
            index.append(.integer(run.first ?? 0))
            index.append(.integer(run.count))
            for entry in run {
                let offset = offsets[entry] ?? 0
                rows.append(1)
                rows.append(UInt8truncating(offset >> 24))
                rows.append(UInt8truncating(offset >> 16))
                rows.append(UInt8truncating(offset >> 8))
                rows.append(UInt8truncating(offset))
                rows.append(0)
                rows.append(0)
            }
        }
        var dictionary = updatedTrailer(trailer, size: size, previous: previous)
        dictionary["Type"] = .name("XRef")
        dictionary["W"] = .array([.integer(1), .integer(4), .integer(2)])
        dictionary["Index"] = .array(index)
        dictionary["Length"] = .integer(rows.count)
        // An appended section carries its own entries only, so nothing here is compressed
        // and no object stream is referenced.
        dictionary["Filter"] = nil
        dictionary["DecodeParms"] = nil
        var output = Array("\(number) 0 obj\n".utf8)
        output += write(.stream(dictionary: dictionary, encoded: rows))
        output += Array("\nendobj\n".utf8)
        return output
    }

    private static func UInt8truncating(_ value: Int) -> UInt8 { UInt8(value & 0xFF) }

    private static func updatedTrailer(_ trailer: [String: PDFObjectFile.Object], size: Int,
                                       previous: Int) -> [String: PDFObjectFile.Object] {
        var updated: [String: PDFObjectFile.Object] = [:]
        for key in ["Root", "Info"] {
            if let value = trailer[key] { updated[key] = value }
        }
        updated["Size"] = .integer(size)
        updated["Prev"] = .integer(previous)
        // The first half of `/ID` names the document and never changes; the second names
        // this revision of it, which is exactly what an update makes a new one of.
        var identifier: [PDFObjectFile.Object] = []
        if case let .array(existing)? = trailer["ID"], let first = existing.first {
            identifier = [first]
        } else {
            identifier = [.string(randomIdentifier())]
        }
        identifier.append(.string(randomIdentifier()))
        updated["ID"] = .array(identifier)
        return updated
    }

    private static func randomIdentifier() -> [UInt8] {
        (0..<16).map { _ in UInt8.random(in: 0...255) }
    }

    private static func runs(of numbers: [Int]) -> [[Int]] {
        var output: [[Int]] = []
        for number in numbers {
            if var last = output.last, let previous = last.last, previous + 1 == number {
                last.append(number)
                output[output.count - 1] = last
            } else {
                output.append([number])
            }
        }
        return output
    }

    // MARK: - Serialization

    private static func write(_ object: PDFObjectFile.Object) -> [UInt8] {
        switch object {
        case .null:
            return Array("null".utf8)
        case let .boolean(value):
            return Array((value ? "true" : "false").utf8)
        case let .integer(value):
            return Array("\(value)".utf8)
        case let .real(value):
            return Array(number(value).utf8)
        case let .name(value):
            return Array("/\(escapedName(value))".utf8)
        case let .string(bytes):
            return escapedString(bytes)
        case let .reference(number, generation):
            return Array("\(number) \(generation) R".utf8)
        case let .array(items):
            var output = Array("[".utf8)
            for (position, item) in items.enumerated() {
                if position > 0 { output.append(UInt8(ascii: " ")) }
                output += write(item)
            }
            output += Array("]".utf8)
            return output
        case let .dictionary(entries):
            return writeDictionary(entries)
        case let .stream(dictionary, encoded):
            var updated = dictionary
            updated["Length"] = .integer(encoded.count)
            var output = writeDictionary(updated)
            output += Array("\nstream\n".utf8)
            output += encoded
            output += Array("\nendstream".utf8)
            return output
        }
    }

    private static func writeDictionary(_ entries: [String: PDFObjectFile.Object]) -> [UInt8] {
        var output = Array("<<".utf8)
        // Sorted so two saves of the same edit produce the same bytes, which is what makes
        // a regression here visible in a diff.
        for key in entries.keys.sorted() {
            guard let value = entries[key] else { continue }
            output += Array("/\(escapedName(key)) ".utf8)
            output += write(value)
            output.append(UInt8(ascii: " "))
        }
        output += Array(">>".utf8)
        return output
    }

    private static func escapedName(_ name: String) -> String {
        var output = ""
        for byte in Array(name.utf8) {
            if byte <= 0x20 || byte >= 0x7F || PDFObjectFile.Scanner.isDelimiter(byte)
                || byte == UInt8(ascii: "#") {
                output += String(format: "#%02X", byte)
            } else {
                output.append(Character(UnicodeScalar(byte)))
            }
        }
        return output
    }

    private static func escapedString(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = [UInt8(ascii: "(")]
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"):
                output.append(UInt8(ascii: "\\"))
                output.append(byte)
            case 0x0A:
                output += Array("\\n".utf8)
            case 0x0D:
                output += Array("\\r".utf8)
            case 0x09:
                output += Array("\\t".utf8)
            case 0x08:
                output += Array("\\b".utf8)
            case 0x0C:
                output += Array("\\f".utf8)
            default:
                output.append(byte)
            }
        }
        output.append(UInt8(ascii: ")"))
        return output
    }

    /// PDF has no exponent notation, so a real has to be written out in full. Five decimal
    /// places is finer than a typesetter's grid and keeps the numbers short.
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return "\(Int(value))" }
        var text = String(format: "%.5f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }

    private static func number(_ value: CGFloat) -> String { number(Double(value)) }

    // MARK: - Landing it on disk

    /// Clone, append, swap. The clone is copy-on-write on APFS, so this costs the appended
    /// bytes rather than the size of the book, and the original is only replaced once the
    /// update is fully written.
    private static func commit(_ update: [UInt8], to url: URL) throws {
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).fyolo-marks")
        try? FileManager.default.removeItem(at: staged)
        do {
            try FileManager.default.copyItem(at: url, to: staged)
            let handle = try FileHandle(forWritingTo: staged)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(update))
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw Failure.io(error.localizedDescription)
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw Failure.io(error.localizedDescription)
        }
    }
}
