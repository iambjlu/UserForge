import Foundation
import Network

/// 把 127.0.0.1:listenPort 的 TCP 連線轉發到 127.0.0.1:targetPort。
public final class PortForwarder {
    private let queue = DispatchQueue(label: "UserForge.forwarder")
    private var listener: NWListener?
    private var active = 0

    public var onEvent: ((String) -> Void)?

    public init() {}

    public var isRunning: Bool { queue.sync { listener != nil } }
    public var activeConnections: Int { queue.sync { active } }

    public func start(listenPort: Int, targetPort: Int) throws {
        stop()
        guard let lp = NWEndpoint.Port(rawValue: UInt16(clamping: listenPort)), listenPort > 0,
              let tp = NWEndpoint.Port(rawValue: UInt16(clamping: targetPort)), targetPort > 0
        else { throw SandboxError("埠號無效") }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: lp)
        let listener = try NWListener(using: params)

        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        var signalled = false
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if !signalled { signalled = true; ready.signal() }
                self?.onEvent?("開始轉發 127.0.0.1:\(listenPort) → 127.0.0.1:\(targetPort)")
            case .failed(let error):
                failure = error.localizedDescription
                if !signalled { signalled = true; ready.signal() }
                self?.queue.async { self?.listener = nil }
                self?.onEvent?("轉發失敗: \(error.localizedDescription)")
            case .cancelled:
                self?.onEvent?("已停止轉發")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] inbound in
            self?.accept(inbound, target: tp)
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            throw SandboxError("啟動轉發逾時")
        }
        if let failure {
            listener.cancel()
            throw SandboxError("無法監聽 \(listenPort): \(failure)")
        }
        queue.sync { self.listener = listener }
    }

    public func stop() {
        let l = queue.sync { () -> NWListener? in
            let l = listener
            listener = nil
            return l
        }
        l?.cancel()
    }

    // MARK: - 連線處理（全部在 queue 上執行）

    private func accept(_ inbound: NWConnection, target: NWEndpoint.Port) {
        let outbound = NWConnection(host: "127.0.0.1", port: target, using: .tcp)
        var closed = false
        active += 1
        let close: () -> Void = { [weak self] in
            if closed { return }
            closed = true
            inbound.cancel()
            outbound.cancel()
            self?.active -= 1
        }
        // 兩個方向都送完 EOF 才關閉，才能支援只關閉寫入端的半關閉連線
        var finishedDirections = 0
        let directionDone: () -> Void = {
            finishedDirections += 1
            if finishedDirections == 2 { close() }
        }
        inbound.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: close()
            default: break
            }
        }
        outbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.pump(from: inbound, to: outbound, done: directionDone, close: close)
                self?.pump(from: outbound, to: inbound, done: directionDone, close: close)
            case .failed, .cancelled: close()
            default: break
            }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
    }

    private func pump(from a: NWConnection, to b: NWConnection,
                      done: @escaping () -> Void, close: @escaping () -> Void) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if error != nil { close(); return }
            let next: () -> Void = {
                if isComplete {
                    b.send(content: nil, contentContext: .finalMessage, isComplete: true,
                           completion: .contentProcessed { _ in done() })
                } else {
                    self?.pump(from: a, to: b, done: done, close: close)
                }
            }
            if let data, !data.isEmpty {
                b.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { close() } else { next() }
                })
            } else {
                next()
            }
        }
    }
}
