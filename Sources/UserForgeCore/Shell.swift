import Foundation

public struct SandboxError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct CommandResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
}

private final class Capture {
    var out = Data()
    var err = Data()
}

public enum Shell {
    /// 執行外部程式並收集輸出。`path` 必須是完整路徑。
    @discardableResult
    public static func run(_ path: String, _ args: [String], input: String? = nil) throws -> CommandResult {
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        try process.run()

        let capture = Capture()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            capture.out = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            capture.err = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if let input { try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? inPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        group.wait()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: capture.out, as: UTF8.self),
            stderr: String(decoding: capture.err, as: UTF8.self))
    }
}

/// 以 root 身分執行指令。已是 root 就直接執行，否則用 `sudo -S`，密碼只經由 stdin 傳遞。
public struct Privileged {
    private let password: String?
    public init(password: String?) { self.password = password }

    @discardableResult
    public func run(_ command: [String], allowFailure: Bool = false) throws -> CommandResult {
        let result: CommandResult
        if geteuid() == 0 {
            result = try Shell.run(command[0], Array(command.dropFirst()))
        } else {
            guard let password, !password.isEmpty else { throw SandboxError("需要管理員密碼") }
            result = try Shell.run("/usr/bin/sudo", ["-k", "-S", "-p", "", "--"] + command, input: password + "\n")
            if !result.ok, result.stderr.contains("incorrect password") || result.stderr.contains("Sorry, try again") {
                throw SandboxError("管理員密碼錯誤")
            }
        }
        if !result.ok && !allowFailure {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            var message = "\(URL(fileURLWithPath: command[0]).lastPathComponent) 失敗 (\(result.status)): \(detail)"
            if detail.contains("Operation not permitted") || detail.contains("Permission denied") {
                message += "\n" + FullDiskAccess.hint
            }
            throw SandboxError(message)
        }
        return result
    }
}
