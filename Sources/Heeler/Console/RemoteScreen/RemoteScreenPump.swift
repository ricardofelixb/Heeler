import Foundation

/// Moves bytes between a connected non-blocking socket and the viewer:
/// whatever arrives is handed to `onData` a read's worth at a time, and
/// `write` queues bytes until the socket takes them. `onEnd` runs once, when
/// the far side closes or the socket fails, never after `close()`.
final class RemoteScreenPump: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.heeler.remote-screen")
    private let descriptor: Int32
    private let onData: @Sendable (Data) -> Void
    private let onEnd: @Sendable () -> Void
    // Owned by `queue`.
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var pending = Data()
    private var finished = false

    init(
        descriptor: Int32,
        onData: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) {
        self.descriptor = descriptor
        self.onData = onData
        self.onEnd = onEnd
    }

    func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            readSource = source
            source.resume()
        }
    }

    func write(_ data: Data) {
        queue.async { [self] in
            guard !finished else { return }
            pending.append(data)
            flush()
        }
    }

    /// Stops both directions and closes the socket, without `onEnd`.
    func close() {
        queue.async { [self] in finish(notify: false) }
    }

    private func drain() {
        var chunk = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while chunk.count < 512 * 1024 {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                chunk.append(buffer, count: count)
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { break }
            if !chunk.isEmpty { onData(chunk) }
            finish(notify: true)
            return
        }
        if !chunk.isEmpty { onData(chunk) }
    }

    private func flush() {
        while !pending.isEmpty {
            let count = pending.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                pending.removeFirst(count)
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(
                        fileDescriptor: descriptor, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    writeSource = source
                    source.resume()
                }
                return
            }
            finish(notify: true)
            return
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func finish(notify: Bool) {
        guard !finished else { return }
        finished = true
        pending.removeAll()
        writeSource?.cancel()
        writeSource = nil
        if let readSource {
            // The socket closes once no handler can still be reading it.
            readSource.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
            readSource.cancel()
            self.readSource = nil
        } else {
            Darwin.close(descriptor)
        }
        if notify { onEnd() }
    }
}
