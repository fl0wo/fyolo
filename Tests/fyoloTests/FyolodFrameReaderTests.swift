import FyoloShared
import XCTest

/// A WebSocket message boundary is not a protocol frame boundary.
///
/// The daemon's listener is a splice: it copies the same framed stream a Unix
/// socket carries into binary messages of whatever size its copy loop happened
/// to read. So one message may hold three frames, or a third of one, and the
/// Mac's `readFrame` — which pulls exactly as many bytes as a header asks for
/// from a blocking descriptor — has no equivalent on that side.
///
/// Every failure here is silent by nature: a reader that mis-slices does not
/// crash, it hands the app a `hello_ok` that will not decode, or PTY bytes at a
/// garbage offset that paint as noise.
final class FyolodFrameReaderTests: XCTestCase {
    private func frame(_ kind: Fyolod.FrameKind, _ payload: String) -> Data {
        Fyolod.frame(kind: kind, payload: Data(payload.utf8))
    }

    func testOneMessageCarryingOneFrame() throws {
        var reader = Fyolod.FrameReader()
        let frames = try reader.append(frame(.control, #"{"op":"hello_ok"}"#))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.kind, .control)
        XCTAssertEqual(frames.first?.payload, Data(#"{"op":"hello_ok"}"#.utf8))
    }

    /// The listener's own test suite proves a `hello` split across two binary
    /// messages must reassemble; this is that case from the client's side.
    func testAFrameSplitAcrossTwoMessagesReassembles() throws {
        var reader = Fyolod.FrameReader()
        let whole = frame(.control, #"{"op":"hello_ok","host_id":"h_1"}"#)
        let cut = whole.index(whole.startIndex, offsetBy: 9)

        XCTAssertTrue(try reader.append(Data(whole[..<cut])).isEmpty)
        let frames = try reader.append(Data(whole[cut...]))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.payload, Data(#"{"op":"hello_ok","host_id":"h_1"}"#.utf8))
    }

    /// The header itself can straddle a message, which is the worse half: a
    /// reader that reads a length out of four bytes it does not have yet is
    /// wrong about every frame after it.
    func testAHeaderSplitMidLengthReassembles() throws {
        var reader = Fyolod.FrameReader()
        let whole = frame(.data, "ok")
        let cut = whole.index(whole.startIndex, offsetBy: 3)

        XCTAssertTrue(try reader.append(Data(whole[..<cut])).isEmpty)
        let frames = try reader.append(Data(whole[cut...]))
        XCTAssertEqual(frames.map(\.kind), [.data])
        XCTAssertEqual(frames.first?.payload, Data("ok".utf8))
    }

    func testOneMessageCarryingThreeFrames() throws {
        var reader = Fyolod.FrameReader()
        var chunk = frame(.control, "{}")
        chunk.append(frame(.data, "abc"))
        chunk.append(frame(.event, #"{"ev":"ready"}"#))

        let frames = try reader.append(chunk)
        XCTAssertEqual(frames.map(\.kind), [.control, .data, .event])
        XCTAssertEqual(frames[1].payload, Data("abc".utf8))
    }

    /// A zero-length payload is legal (`detach` sends none) and must not stall
    /// the loop waiting for bytes that are never coming.
    func testAnEmptyPayloadIsAWholeFrame() throws {
        var reader = Fyolod.FrameReader()
        let frames = try reader.append(Fyolod.frame(kind: .resize, payload: Data()))
        XCTAssertEqual(frames.map(\.kind), [.resize])
        XCTAssertEqual(frames.first?.payload.count, 0)
    }

    /// Byte-at-a-time delivery is the pathological case a proxy can produce, and
    /// the frame must appear exactly once — on the last byte, not before it.
    func testByteAtATimeDeliveryYieldsTheFrameOnce() throws {
        var reader = Fyolod.FrameReader()
        let whole = frame(.data, "hello")
        var delivered: [(kind: Fyolod.FrameKind, payload: Data)] = []
        for byte in whole {
            delivered += try reader.append(Data([byte]))
        }
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.payload, Data("hello".utf8))
    }

    /// An undefined kind byte means the stream has lost alignment, and every
    /// frame read after it would be garbage at a garbage offset. Failing loudly
    /// is what turns that into a dropped connection instead of a painted mess.
    func testAnUnknownKindIsAProtocolError() {
        var reader = Fyolod.FrameReader()
        var chunk = Data([0x5A]) // 'Z' — not a frame kind
        chunk.append(contentsOf: [0, 0, 0, 0])
        XCTAssertThrowsError(try reader.append(chunk))
    }

    func testAnOversizedLengthIsAProtocolError() {
        var reader = Fyolod.FrameReader()
        var chunk = Data([Fyolod.FrameKind.data.rawValue])
        chunk.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try reader.append(chunk))
    }

    /// A socket that died mid-frame leaves bytes that mean nothing to the next
    /// one; the reset is what keeps a reconnect from reading the new stream at
    /// the old one's offset.
    func testResetDropsAPartialFrame() throws {
        var reader = Fyolod.FrameReader()
        let whole = frame(.data, "abcdef")
        XCTAssertTrue(try reader.append(whole.prefix(7)).isEmpty)
        reader.reset()
        let frames = try reader.append(frame(.data, "xy"))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.payload, Data("xy".utf8))
    }
}
