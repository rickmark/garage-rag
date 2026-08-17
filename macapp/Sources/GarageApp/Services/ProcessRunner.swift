import Foundation

/// A line of output captured from a subprocess, for the log viewer.
struct LogLine: Identifiable {
    enum Stream { case stdout, stderr }
    let id = UUID()
    let date = Date()
    let stream: Stream
    let text: String
    let source: String
}

/// Thin wrapper around Process that streams stdout/stderr line-by-line to a
/// callback and reports exit status. Used for both the long-running Postgres
/// server process and one-shot `garage` CLI invocations.
final class ProcessRunner {
    private(set) var process: Process?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    @discardableResult
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        source: String,
        onLine: @escaping (LogLine) -> Void
    ) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle: handle, buffer: \.stdoutBuffer, stream: .stdout, source: source, onLine: onLine)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle: handle, buffer: \.stderrBuffer, stream: .stderr, source: source, onLine: onLine)
        }

        self.process = process
        try process.run()
        return process
    }

    /// Runs to completion and returns (exitCode, combined output). For short CLI calls.
    static func runSync(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "failed to launch \(executable.path): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func consume(
        handle: FileHandle,
        buffer: ReferenceWritableKeyPath<ProcessRunner, Data>,
        stream: LogLine.Stream,
        source: String,
        onLine: @escaping (LogLine) -> Void
    ) {
        let data = handle.availableData
        guard !data.isEmpty else { return }
        self[keyPath: buffer].append(data)
        while let range = self[keyPath: buffer].firstRange(of: Data([0x0A])) {
            let lineData = self[keyPath: buffer].subdata(in: self[keyPath: buffer].startIndex..<range.lowerBound)
            self[keyPath: buffer].removeSubrange(self[keyPath: buffer].startIndex..<range.upperBound)
            let text = String(data: lineData, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                onLine(LogLine(stream: stream, text: text, source: source))
            }
        }
    }

    func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }
}
