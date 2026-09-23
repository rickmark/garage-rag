import Darwin
import Foundation
import OSLog

// Same subsystem/category the app's log view files under "garage CLI" (OSLogStreamService).
let launcherLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.cli", category: "GarageCLI")

/// Copies the launcher's stdout/stderr to the unified log line by line while still
/// writing them through to the original descriptors.
final class LauncherOutputCapturer {
    static let shared = LauncherOutputCapturer()
    private var origStdout: Int32 = -1
    private var origStderr: Int32 = -1
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let lock = NSLock()

    func start() {
        origStdout = dup(STDOUT_FILENO)
        origStderr = dup(STDERR_FILENO)

        let outPipe = Pipe()
        let errPipe = Pipe()
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        fflush(stdout)
        fflush(stderr)
        dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(errPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let outOrig = origStdout
        let errOrig = origStderr

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if outOrig >= 0 {
                data.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        _ = write(outOrig, base, data.count)
                    }
                }
            }
            self?.process(data: data, isStderr: false)
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if errOrig >= 0 {
                data.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        _ = write(errOrig, base, data.count)
                    }
                }
            }
            self?.process(data: data, isStderr: true)
        }
    }

    private func process(data: Data, isStderr: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStderr {
            stderrBuffer.append(data)
            while let range = stderrBuffer.firstRange(of: Data([0x0A])) {
                let lineData = stderrBuffer.subdata(in: stderrBuffer.startIndex..<range.lowerBound)
                stderrBuffer.removeSubrange(stderrBuffer.startIndex..<range.upperBound)
                if let line = String(data: lineData, encoding: .utf8), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    launcherLogger.error("\(line, privacy: .public)")
                }
            }
        } else {
            stdoutBuffer.append(data)
            while let range = stdoutBuffer.firstRange(of: Data([0x0A])) {
                let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
                if let line = String(data: lineData, encoding: .utf8), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    launcherLogger.info("\(line, privacy: .public)")
                }
            }
        }
    }

    func flush() {
        fflush(stdout)
        fflush(stderr)
        lock.lock()
        defer { lock.unlock() }
        if !stdoutBuffer.isEmpty, let line = String(data: stdoutBuffer, encoding: .utf8), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherLogger.info("\(line, privacy: .public)")
            stdoutBuffer.removeAll()
        }
        if !stderrBuffer.isEmpty, let line = String(data: stderrBuffer, encoding: .utf8), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherLogger.error("\(line, privacy: .public)")
            stderrBuffer.removeAll()
        }
    }
}
