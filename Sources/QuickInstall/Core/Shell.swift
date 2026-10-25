import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

enum ShellError: LocalizedError {
    case failed(command: String, result: ShellResult)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .failed(command, result):
            let detail = result.stderr.trimmed.isEmpty ? result.stdout.trimmed : result.stderr.trimmed
            return "\(command) ist fehlgeschlagen (Code \(result.status)).\n\(detail)"
        case .cancelled:
            return "Vom Benutzer abgebrochen."
        }
    }
}

enum Shell {
    /// Runs a command synchronously and collects its output. Call from a background task.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], input: String? = nil) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Always attach stdin so tools never wait for a terminal.
        process.standardInput = stdinPipe

        try process.run()
        if let input, let data = input.data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Read both pipes concurrently so a full stderr buffer can't block the process.
        let stderrBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrBox.data, as: UTF8.self))
    }

    /// Runs a command and throws if it exits with a non-zero status.
    @discardableResult
    static func check(_ executable: String, _ arguments: [String], input: String? = nil) throws -> ShellResult {
        let result = try run(executable, arguments, input: input)
        guard result.succeeded else {
            let name = (executable as NSString).lastPathComponent
            throw ShellError.failed(command: ([name] + arguments.prefix(1)).joined(separator: " "), result: result)
        }
        return result
    }

    /// Single-quotes a string for /bin/sh.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Runs shell scripts as root after the standard macOS administrator password prompt.
enum Privileged {
    /// `build` receives a private temporary directory (for helper files such as file lists)
    /// and returns the script to run. Returns the script's output.
    @discardableResult
    static func run(prompt: String, build: (URL) throws -> String) throws -> String {
        let dir = try Paths.makeTemporaryDirectory(prefix: "QuickInstall-admin")
        defer { try? FileManager.default.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("run.sh")
        try build(dir).write(to: scriptURL, atomically: true, encoding: .utf8)

        let command = "/bin/sh " + Shell.quote(scriptURL.path)
        let appleScript =
            "do shell script \(appleScriptString(command)) with administrator privileges with prompt \(appleScriptString(prompt))"
        let result = try Shell.run("/usr/bin/osascript", ["-e", appleScript])
        guard result.succeeded else {
            if result.stderr.contains("-128") { throw ShellError.cancelled }
            throw ShellError.failed(command: "Befehl mit Administratorrechten", result: result)
        }
        // `do shell script` turns line breaks into carriage returns.
        return result.stdout.replacingOccurrences(of: "\r", with: "\n")
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
