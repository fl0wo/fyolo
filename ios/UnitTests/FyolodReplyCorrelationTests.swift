@testable import FyoloMobile
import FyoloShared
import XCTest

/// One connection carries every request this backend makes, and the daemon
/// answers them in whatever order it finishes them in. Matching a reply to the
/// oldest request of its verb held only while exactly one was ever outstanding;
/// the moment two are, the second reply lands on the first caller and the file
/// on screen is the wrong file. Nothing throws when that happens, which is why
/// it needs a test rather than a careful reader.
///
/// The replies below are the daemon's own JSON (`fyolod/src/protocol.rs`), run
/// through the real decode so the `re` is read the way the channel reads it.
final class FyolodReplyCorrelationTests: XCTestCase {
    /// A backend dials nothing until `start()`, so this opens no socket and its
    /// sends land on a nil task.
    private func makeBackend(sessionID: String? = nil) -> FyolodBackend {
        guard let url = URL(string: "ws://127.0.0.1:9/ws") else {
            fatalError("a literal URL that does not parse")
        }
        return FyolodBackend(
            endpoint: DeviceEndpoint(kind: .fyolod, url: url), sessionID: sessionID)
    }

    private let project = FyolodRoster.projectID(forRoot: "/srv/repo")

    /// `nextSeq` pre-increments from 1, so the first two requests a fresh
    /// backend sends are stamped 2 and 3. If that changes, these fail loudly —
    /// which is the point: the ids are the contract now.
    private let firstRequest: UInt64 = 2
    private let secondRequest: UInt64 = 3

    private func reply(_ json: String) throws -> FyolodChannel.Reply {
        let payload = Data(json.utf8)
        return FyolodChannel.Reply(
            responseID: Fyolod.responseID(of: payload),
            control: try Fyolod.decodeControl(payload)
        )
    }

    /// The `F` layout from `encode_file_chunk`: request u64be, offset u64be,
    /// last u8, then the bytes. Built by hand so the test holds that layout.
    private func fileChunk(request: UInt64, offset: UInt64, last: Bool, text: String) -> Data {
        var payload = Data()
        withUnsafeBytes(of: request.bigEndian) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: offset.bigEndian) { payload.append(contentsOf: $0) }
        payload.append(last ? 1 : 0)
        payload.append(Data(text.utf8))
        return payload
    }

    private func header(request: UInt64, length: Int) -> String {
        #"{"op":"fs_file","size":\#(length),"offset":0,"length":\#(length),"re":\#(request)}"#
    }

    // MARK: - The reason this exists

    /// Two reads in flight, answered in the reverse order they were asked. Each
    /// caller must get its own file. Under the old order-matched rule the first
    /// reply took the first path and both files came back mislabelled.
    func testTwoReadsAnsweredOutOfOrderEachReachTheRightCaller() throws {
        let backend = makeBackend()
        var delivered: [(path: String, contents: String)] = []
        backend.onFile = { file in
            delivered.append((file.path, String(decoding: file.data ?? Data(), as: UTF8.self)))
        }

        backend.readFile(projectID: project, path: "one.txt", darkAppearance: false)
        backend.readFile(projectID: project, path: "two.txt", darkAppearance: false)

        // The device finishes the second read first.
        try backend.receive(reply(header(request: secondRequest, length: 5)))
        backend.receiveFileChunk(
            fileChunk(request: secondRequest, offset: 0, last: true, text: "TWO!!"))
        try backend.receive(reply(header(request: firstRequest, length: 3)))
        backend.receiveFileChunk(
            fileChunk(request: firstRequest, offset: 0, last: true, text: "ONE"))

        XCTAssertEqual(delivered.map(\.path), ["two.txt", "one.txt"])
        XCTAssertEqual(delivered.map(\.contents), ["TWO!!", "ONE"])
    }

    /// Interleaved chunks are the sharper version of the same failure: bytes of
    /// two files arriving alternately must not concatenate into one.
    func testInterleavedChunksDoNotBleedBetweenReads() throws {
        let backend = makeBackend()
        var byPath: [String: String] = [:]
        backend.onFile = { file in
            byPath[file.path] = String(decoding: file.data ?? Data(), as: UTF8.self)
        }

        backend.readFile(projectID: project, path: "one.txt", darkAppearance: false)
        backend.readFile(projectID: project, path: "two.txt", darkAppearance: false)
        try backend.receive(reply(header(request: firstRequest, length: 4)))
        try backend.receive(reply(header(request: secondRequest, length: 4)))

        backend.receiveFileChunk(
            fileChunk(request: firstRequest, offset: 0, last: false, text: "aa"))
        backend.receiveFileChunk(
            fileChunk(request: secondRequest, offset: 0, last: false, text: "bb"))
        backend.receiveFileChunk(
            fileChunk(request: firstRequest, offset: 2, last: true, text: "aa"))
        backend.receiveFileChunk(
            fileChunk(request: secondRequest, offset: 2, last: true, text: "bb"))

        XCTAssertEqual(byPath, ["one.txt": "aaaa", "two.txt": "bbbb"])
    }

    /// A search and a read in flight together. The search reply must not consume
    /// the read, and vice versa — the old rule kept a queue per verb, so this
    /// already held, but it has to survive the rewrite.
    func testASearchReplyDoesNotConsumeAPendingRead() throws {
        let backend = makeBackend()
        var searched: [String] = []
        var files: [String] = []
        backend.onSearchResults = { query, _, _ in searched.append(query) }
        backend.onFile = { files.append($0.path) }

        backend.readFile(projectID: project, path: "one.txt", darkAppearance: false)
        backend.searchFiles(projectID: project, query: "needle")

        try backend.receive(reply(
            #"{"op":"fs_matched","paths":["a.swift"],"coverage":1.0,"re":\#(secondRequest)}"#))
        try backend.receive(reply(header(request: firstRequest, length: 0)))

        XCTAssertEqual(searched, ["needle"])
        XCTAssertEqual(files, ["one.txt"])
    }

    // MARK: - Refusals

    /// The bug this change fixes. A refusal names the request that caused it, so
    /// failing the search must leave the read alive. Attributing it to "whatever
    /// is outstanding" cancelled the read instead, and the read then hung until
    /// the socket dropped.
    func testARefusalFailsOnlyTheRequestThatCausedIt() throws {
        let backend = makeBackend()
        var errors: [String] = []
        var files: [String] = []
        backend.onError = { errors.append($0) }
        backend.onFile = { files.append($0.path) }

        backend.readFile(projectID: project, path: "one.txt", darkAppearance: false)
        backend.searchFiles(projectID: project, query: "needle")

        try backend.receive(reply(
            #"{"op":"error","re":\#(secondRequest),"code":"denied","message":"no index"}"#))
        XCTAssertEqual(errors, ["no index"])

        // The read was never touched, so it still answers.
        try backend.receive(reply(header(request: firstRequest, length: 3)))
        backend.receiveFileChunk(
            fileChunk(request: firstRequest, offset: 0, last: true, text: "ONE"))
        XCTAssertEqual(files, ["one.txt"])
    }

    /// A refusal that belongs to no request — a protocol error, a denied
    /// capability — still has to reach the screen. Silently dropping it is how a
    /// connection looks fine while doing nothing.
    func testAnUnattributedRefusalIsStillReported() throws {
        let backend = makeBackend()
        var errors: [String] = []
        backend.onError = { errors.append($0) }

        backend.readFile(projectID: project, path: "one.txt", darkAppearance: false)
        try backend.receive(reply(
            #"{"op":"error","code":"proto_error","message":"bad frame"}"#))

        XCTAssertEqual(errors, ["bad frame"])
    }

    /// …and it must not evict the request it does not name.
    func testAnUnattributedRefusalLeavesRequestsAlone() throws {
        let backend = makeBackend()
        var files: [String] = []
        backend.onFile = { files.append($0.path) }

        backend.readFile(projectID: project, path: "one.txt", darkAppearance: false)
        try backend.receive(reply(
            #"{"op":"error","code":"proto_error","message":"bad frame"}"#))
        try backend.receive(reply(header(request: firstRequest, length: 3)))
        backend.receiveFileChunk(
            fileChunk(request: firstRequest, offset: 0, last: true, text: "ONE"))

        XCTAssertEqual(files, ["one.txt"])
    }

    func testAnUnattributedUploadChunkRefusalAdvancesTheTransferQueue() throws {
        let backend = makeBackend(sessionID: "session")
        var uploaded: [String] = []
        backend.onUploaded = { uploaded.append($0) }

        backend.upload(projectID: project, name: "first.txt", data: Data("one".utf8))
        backend.upload(projectID: project, name: "second.txt", data: Data("two".utf8))

        try backend.receive(reply(
            #"{"op":"upload_opened","upload_id":"first","offset":0,"re":\#(firstRequest)}"#))
        try backend.receive(reply(
            #"{"op":"error","code":"denied","message":"upload expired"}"#))

        try backend.receive(reply(
            #"{"op":"upload_opened","upload_id":"second","offset":0,"re":\#(secondRequest)}"#))
        try backend.receive(reply(
            #"{"op":"upload_ack","upload_id":"second","offset":3}"#))
        try backend.receive(reply(
            #"{"op":"upload_committed","path":"/tmp/second.txt","mtime":1,"re":4}"#))

        XCTAssertEqual(uploaded, ["/tmp/second.txt"])
    }

    // MARK: - Degrades

    /// A daemon too old to stamp its replies leaves `re` absent. With exactly one
    /// request outstanding there is nothing to confuse it with, so it is still
    /// placed rather than dropped on the floor.
    func testAnUnstampedReplyIsPlacedWhenOnlyOneRequestIsWaiting() throws {
        let backend = makeBackend()
        var searched: [String] = []
        backend.onSearchResults = { query, _, _ in searched.append(query) }

        backend.searchFiles(projectID: project, query: "needle")
        try backend.receive(reply(
            #"{"op":"fs_matched","paths":["a.swift"],"coverage":1.0}"#))

        XCTAssertEqual(searched, ["needle"])
    }

    /// Two waiting and no `re` is genuinely ambiguous. Guessing is the behaviour
    /// this correlation exists to end, so nothing is delivered.
    func testAnUnstampedReplyIsDroppedWhenTwoRequestsAreWaiting() throws {
        let backend = makeBackend()
        var searched: [String] = []
        backend.onSearchResults = { query, _, _ in searched.append(query) }

        backend.searchFiles(projectID: project, query: "first")
        backend.searchFiles(projectID: project, query: "second")
        try backend.receive(reply(
            #"{"op":"fs_matched","paths":["a.swift"],"coverage":1.0}"#))

        XCTAssertTrue(searched.isEmpty)
    }

    /// A reply naming a request that was never made, or one already answered,
    /// belongs to nobody and must not be handed to whoever happens to be waiting.
    func testAReplyForAnUnknownRequestIsIgnored() throws {
        let backend = makeBackend()
        var files: [String] = []
        backend.onFile = { files.append($0.path) }

        backend.readFile(projectID: project, path: "one.txt", darkAppearance: false)
        try backend.receive(reply(header(request: 999, length: 0)))

        XCTAssertTrue(files.isEmpty)
    }
}
