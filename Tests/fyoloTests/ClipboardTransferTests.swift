import AppKit
import XCTest
import FyoloShared
@testable import fyolo

/// The clipboard decisions on the viewer↔device boundary.
///
/// Misreading the clipboard sends a basename where an agent needs a path (or
/// a text paste down the transfer plane, or swallows a normal ⌘V), and a byte
/// of drift in the `U` chunk layout makes the daemon reject the frame outright
/// — there is no partial credit on a wire format, and the failure surfaces as
/// a paste that silently does nothing, which is the bug this whole path exists
/// to end.
@MainActor
final class ClipboardTransferTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("sh.fyolo.tests.clipboard"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    private func writeFiles(
        _ paths: [String],
        filenameText: Bool = false,
        isDirectory: Bool = false
    ) {
        pasteboard.clearContents()
        let urls = paths.map { URL(fileURLWithPath: $0, isDirectory: isDirectory) as NSURL }
        XCTAssertTrue(pasteboard.writeObjects(urls), "failed to write \(paths)")
        if filenameText {
            pasteboard.setString(
                paths.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"),
                forType: .string)
        }
    }

    /// A 1×1 image encoded the way the pasteboard would carry it.
    private func imageData(_ type: NSBitmapImageRep.FileType) -> Data {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)
        guard let representation,
              let data = representation.representation(using: type, properties: [:])
        else {
            XCTFail("could not build a \(type) fixture")
            return Data()
        }
        return data
    }













    /// The file URLs the machine boundary reads. Turning them into prompt text
    /// is libghostty's job now; what still has to be right here is *which*
    /// files a clipboard names, because an image is recognised from that list.
    func testOnlyRealFileURLsAreRead() {
        XCTAssertTrue(ClipboardFilePaths.fileURLs(on: pasteboard).isEmpty, "empty pasteboard")

        pasteboard.clearContents()
        pasteboard.setString("/Users/example/Desktop/example image.png", forType: .string)
        XCTAssertTrue(
            ClipboardFilePaths.fileURLs(on: pasteboard).isEmpty,
            "text that looks like a path is not a file identity")

        pasteboard.clearContents()
        pasteboard.setData(Data("not a url".utf8), forType: .fileURL)
        XCTAssertTrue(ClipboardFilePaths.fileURLs(on: pasteboard).isEmpty, "malformed data")

        guard let remote = URL(string: "https://example.com") else {
            return XCTFail("could not build the https URL")
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([remote as NSURL]))
        XCTAssertTrue(ClipboardFilePaths.fileURLs(on: pasteboard).isEmpty, "a non-file URL")
    }

    /// Order and lexical normalization survive, because the boundary reports
    /// the file it carried by the path the user copied.
    func testFileURLsKeepOrderAndAreStandardized() {
        writeFiles([
            "/Users/example/Desktop/first.txt",
            "/Users/example/foo/../bar/second.txt",
        ])
        XCTAssertEqual(
            ClipboardFilePaths.fileURLs(on: pasteboard).map(\.path),
            ["/Users/example/Desktop/first.txt", "/Users/example/bar/second.txt"])
    }

    /// A Finder-copied image file aimed at a session on another machine. The
    /// path is worthless over there, so the bytes have to travel — this is the
    /// read that decides that.
    func testACopiedImageFileIsReadForTheCrossing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("example image.png")
        let png = imageData(.png)
        try png.write(to: url)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
        pasteboard.setString("example image.png", forType: .string)
        // Finder ships the icon too; reading that instead would send a
        // thumbnail where the user meant the picture.
        pasteboard.setData(imageData(.tiff), forType: .tiff)

        guard case let .image(image) = ClipboardImage.fileOnClipboard(pasteboard) else {
            return XCTFail("a lone copied image file should be read for the crossing")
        }
        XCTAssertEqual(image.data, png, "the file's bytes, not its icon")
        XCTAssertEqual(image.fileExtension, "png")
    }

    /// Everything that is not a lone image file keeps pasting as a path, so a
    /// paste never silently uploads part of what was copied.
    func testOnlyALoneImageFileCrossesTheBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let text = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        let image = directory.appendingPathComponent("shot.png")
        try imageData(.png).write(to: image)
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for (label, urls) in [
            ("an ordinary file", [text]),
            ("a directory", [folder]),
            ("an image beside another file", [image, text]),
        ] {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects(urls.map { $0 as NSURL }))
            guard case .none = ClipboardImage.fileOnClipboard(pasteboard) else {
                return XCTFail("\(label) should keep pasting as a path")
            }
        }
    }

    /// Over the cap the paste is refused out loud rather than falling through
    /// to a local path that resolves to nothing on the far machine.
    func testAnOversizeImageFileIsRefusedRatherThanPastedAsAPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("huge.png")
        var bytes = imageData(.png)
        bytes.append(Data(count: ClipboardImage.maximumFileBytes))
        try bytes.write(to: url)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))

        guard case let .tooLarge(reported, size) = ClipboardImage.fileOnClipboard(pasteboard)
        else {
            return XCTFail("an oversize image should be refused, not silently ignored")
        }
        XCTAssertEqual(reported.lastPathComponent, "huge.png")
        XCTAssertGreaterThan(size, ClipboardImage.maximumFileBytes)
    }

    func testPNGOnTheClipboardIsTakenVerbatim() {
        let png = imageData(.png)
        pasteboard.setData(png, forType: .png)

        let image = ClipboardImage.current(pasteboard)
        XCTAssertEqual(image?.data, png, "PNG travels as-is, not re-encoded")
        XCTAssertEqual(image?.fileExtension, "png")
    }

    /// A screenshot lands as PNG *and* TIFF. The far side wants a file an agent
    /// will open, so the flavor the client picks must not be whichever one the
    /// pasteboard happened to list first.
    func testAScreenshotsPNGIsPreferredOverItsTIFFTwin() {
        let png = imageData(.png)
        pasteboard.setData(imageData(.tiff), forType: .tiff)
        pasteboard.setData(png, forType: .png)

        XCTAssertEqual(ClipboardImage.current(pasteboard)?.data, png)
    }

    /// Only TIFF: re-encoded rather than shipped, because a `.png` name has to
    /// mean PNG bytes on the other machine.
    func testATIFFOnlyClipboardIsReencodedAsPNG() {
        pasteboard.setData(imageData(.tiff), forType: .tiff)

        let image = ClipboardImage.current(pasteboard)
        XCTAssertEqual(image?.fileExtension, "png")
        XCTAssertEqual(image?.data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
                       "the re-encode must actually produce a PNG")
    }

    /// The rule libghostty's wrapper already applies locally, kept identical so
    /// the two layers cannot disagree about what a paste is: a clipboard that
    /// carries text is a text paste, whatever else rides along with it.
    func testAClipboardCarryingTextIsNeverATransfer() {
        pasteboard.setData(imageData(.png), forType: .png)
        pasteboard.setString("git status", forType: .string)

        XCTAssertNil(ClipboardImage.current(pasteboard))
    }

    func testAnEmptyClipboardIsNotATransfer() {
        XCTAssertNil(ClipboardImage.current(pasteboard))
    }

    /// Each paste gets its own name, so two screenshots in one session cannot
    /// collide on a dest the daemon would then refuse as conflicting content.
    func testEachPasteNamesItsOwnFile() {
        let image = ClipboardImage(data: Data([1]), fileExtension: "png")
        XCTAssertTrue(image.scratchFileName.hasPrefix("paste-"))
        XCTAssertTrue(image.scratchFileName.hasSuffix(".png"))
        XCTAssertFalse(image.scratchFileName.contains("/"), "a temp: name is one plain component")
    }

    /// `decode_upload_chunk` in fyolod/src/protocol.rs, byte for byte.
    func testUploadChunkMatchesTheDaemonsLayout() {
        let payload = Fyolod.uploadChunkPayload(
            uploadID: "u_2a", offset: 131_072, data: Data("pasted".utf8))

        XCTAssertEqual(payload, Data([4]) + Data("u_2a".utf8)
            + Data([0, 0, 0, 0, 0, 2, 0, 0])
            + Data("pasted".utf8))
    }

    /// The frame the chunk rides in is capped at 64 KiB by the daemon, and a
    /// client that overruns it gets the frame refused rather than truncated.
    func testAFullChunkStaysInsideTheFrameCap() {
        let payload = Fyolod.uploadChunkPayload(
            uploadID: String(repeating: "u", count: 64),
            offset: 0,
            data: Data(count: Fyolod.uploadChunkSize))

        XCTAssertLessThanOrEqual(payload.count, 64 * 1024)
    }
}
