import Foundation
import Testing

@testable import Heeler

struct RemoteScreenTests {
    @Test func typedPasswordsStayInTheSecretStore() throws {
        let secrets = VolatileSecretStore()
        let store = RemoteScreenSettingsStore(secrets: secrets)
        let host = UUID()

        #expect(store.password(for: host) == nil)
        try store.savePassword("s3cret", for: host)
        #expect(store.password(for: host) == "s3cret")
        #expect(try secrets.read(account: host.uuidString) == Data("s3cret".utf8))

        try store.savePassword(nil, for: host)
        #expect(store.password(for: host) == nil)
    }

    /// The preview's page only runs once it's on screen, and it only goes on
    /// screen once the Host turns out to have one: the check can't wait for it.
    @MainActor
    @Test func theHostIsAskedBeforeThePageIsOnScreen() async throws {
        let store = RemoteScreenSettingsStore(secrets: VolatileSecretStore())
        let none = RemoteScreenSession(hostID: UUID(), store: store, viewOnly: true) { nil }
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { close(descriptors[1]) }
        let stream = HostLoopbackStream(descriptor: descriptors[0]) {}
        let (asked, askedContinuation) = AsyncStream<Void>.makeStream()
        let screen = RemoteScreenSession(hostID: UUID(), store: store, viewOnly: true) {
            askedContinuation.yield()
            return (RemoteScreenProbe(port: 5900, password: nil), stream)
        }
        var asks = asked.makeAsyncIterator()
        #expect(await asks.next() != nil)
        for _ in 0..<200 where none.phase == .connecting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(none.phase == .unavailable)
        screen.stop()
    }

    @Test func probeReadsThePortAndDecodesAVNCPasswordFile() throws {
        // `vncpasswd` stores "password" as dbd83cfd727a1458.
        let file = Data([0xDB, 0xD8, 0x3C, 0xFD, 0x72, 0x7A, 0x14, 0x58]).base64EncodedString()
        #expect(RemoteScreenProbe(output: "port=5999\nvncpasswd=\(file)\n")
            == RemoteScreenProbe(port: 5999, password: "password"))
        #expect(RemoteScreenProbe(output: "port=5900\n") == RemoteScreenProbe(port: 5900, password: nil))
        #expect(RemoteScreenProbe(output: "") == nil)
        #expect(RemoteScreenProbe(output: "port=nope\n") == nil)
    }

    @Test func pumpCarriesBytesBothWaysAndReportsTheFarSideClosing() async throws {
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        _ = fcntl(descriptors[0], F_SETFL, fcntl(descriptors[0], F_GETFL, 0) | O_NONBLOCK)
        let far = descriptors[1]
        defer { close(far) }

        let (received, receivedContinuation) = AsyncStream<Data>.makeStream()
        let (ended, endedContinuation) = AsyncStream<Void>.makeStream()
        let pump = RemoteScreenPump(
            descriptor: descriptors[0],
            onData: { receivedContinuation.yield($0) },
            onEnd: { endedContinuation.yield(); endedContinuation.finish() })
        pump.start()

        // Larger than one socket buffer, so the write side has to wait.
        let outgoing = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        pump.write(outgoing)
        var echoed = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while echoed.count < outgoing.count {
            let count = read(far, &buffer, buffer.count)
            #expect(count > 0)
            if count <= 0 { break }
            echoed.append(buffer, count: count)
        }
        #expect(echoed == outgoing)

        _ = Data("RFB 003.008\n".utf8).withUnsafeBytes { write(far, $0.baseAddress, $0.count) }
        var incoming = received.makeAsyncIterator()
        #expect(await incoming.next() == Data("RFB 003.008\n".utf8))

        shutdown(far, SHUT_RDWR)
        var endings = ended.makeAsyncIterator()
        #expect(await endings.next() != nil)
    }
}
