import Foundation
import Testing

@testable import Heeler

struct RemoteScreenTests {
    @Test func settingsKeepThePasswordInTheSecretStoreAndForgetBoth() throws {
        let suite = "RemoteScreenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = VolatileSecretStore()
        let store = RemoteScreenSettingsStore(suiteName: suite, secrets: secrets)
        let host = UUID()

        #expect(store.settings(for: host) == nil)
        try store.save(RemoteScreenSettings(port: 5999, password: "s3cret"), for: host)
        #expect(store.settings(for: host) == RemoteScreenSettings(port: 5999, password: "s3cret"))
        #expect(try secrets.read(account: host.uuidString) == Data("s3cret".utf8))
        #expect(defaults.dictionaryRepresentation().values.contains { $0 as? String == "s3cret" } == false)

        try store.save(nil, for: host)
        #expect(store.settings(for: host) == nil)
        #expect(try secrets.read(account: host.uuidString) == nil)
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
