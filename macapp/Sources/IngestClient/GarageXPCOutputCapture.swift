import Foundation
import Darwin
import OSLog

private let logger = Logger(subsystem: "me.rickmark.garage", category: "GarageXPCOutputCapture")

/// Captures stdout and stderr streams in-process and buffers them for retrieval over XPC.
/// Preserves console / system logging by tee-ing captured data back to the original file descriptors.
public final class GarageXPCOutputCapture: @unchecked Sendable {
    public static let shared = GarageXPCOutputCapture()

    private let lock = NSLock()
    private var isCapturing = false

    private var originalStdoutFd: Int32 = -1
    private var originalStderrFd: Int32 = -1

    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let maxBufferSize: Int

    public weak var logReceiver: GarageXPCLogReceiverProtocol?

    public init(maxBufferSize: Int = 1_048_576) { // 1 MB default buffer
        self.maxBufferSize = maxBufferSize
    }

    /// Starts capturing stdout and stderr descriptors (fd 1 and fd 2).
    public func startCapturing() {
        lock.lock()
        defer { lock.unlock() }

        guard !isCapturing else { return }

        // Save original file descriptors
        originalStdoutFd = dup(STDOUT_FILENO)
        originalStderrFd = dup(STDERR_FILENO)

        let outPipe = Pipe()
        let errPipe = Pipe()
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        // Redirect stdout and stderr to the pipe write ends
        fflush(stdout)
        fflush(stderr)
        dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(errPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let origOut = originalStdoutFd
        let origErr = originalStderrFd

        // Background reader for stdout
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Tee to original stdout so terminal output still works
            if origOut >= 0 {
                data.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        _ = write(origOut, base, data.count)
                    }
                }
            }

            self?.appendStdoutData(data)
        }

        // Background reader for stderr
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Tee to original stderr
            if origErr >= 0 {
                data.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        _ = write(origErr, base, data.count)
                    }
                }
            }

            self?.appendStderrData(data)
        }

        isCapturing = true
        logger.info("GarageXPCOutputCapture started capturing stdout and stderr.")
    }

    /// Appends data to the stdout buffer.
    private func appendStdoutData(_ data: Data) {
        lock.lock()
        stdoutBuffer.append(data)
        if stdoutBuffer.count > maxBufferSize {
            let overflow = stdoutBuffer.count - maxBufferSize
            stdoutBuffer.removeSubrange(0..<overflow)
        }
        let receiver = logReceiver
        lock.unlock()

        if let receiver = receiver, let text = String(data: data, encoding: .utf8) {
            receiver.didReceiveStdout(text)
        }
    }

    /// Appends data to the stderr buffer.
    private func appendStderrData(_ data: Data) {
        lock.lock()
        stderrBuffer.append(data)
        if stderrBuffer.count > maxBufferSize {
            let overflow = stderrBuffer.count - maxBufferSize
            stderrBuffer.removeSubrange(0..<overflow)
        }
        let receiver = logReceiver
        lock.unlock()

        if let receiver = receiver, let text = String(data: data, encoding: .utf8) {
            receiver.didReceiveStderr(text)
        }
    }

    /// Appends a manual log line to the captured output.
    public func appendCustomLog(stream: String = "stdout", message: String) {
        let formatted = message.hasSuffix("\n") ? message : "\(message)\n"
        if let data = formatted.data(using: .utf8) {
            if stream.lowercased() == "stderr" {
                appendStderrData(data)
            } else {
                appendStdoutData(data)
            }
        }
    }

    /// Fetches the captured stdout and stderr buffers as UTF-8 strings.
    public func fetchLogs(clearBuffer: Bool = false) -> (stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }

        let outText = String(data: stdoutBuffer, encoding: .utf8) ?? ""
        let errText = String(data: stderrBuffer, encoding: .utf8) ?? ""

        if clearBuffer {
            stdoutBuffer.removeAll()
            stderrBuffer.removeAll()
        }

        return (stdout: outText, stderr: errText)
    }

    /// Clears the accumulated stdout and stderr buffers.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
    }

    /// Stops capturing and restores original file descriptors.
    public func stopCapturing() {
        lock.lock()
        defer { lock.unlock() }

        guard isCapturing else { return }

        fflush(stdout)
        fflush(stderr)

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if originalStdoutFd >= 0 {
            dup2(originalStdoutFd, STDOUT_FILENO)
            close(originalStdoutFd)
            originalStdoutFd = -1
        }

        if originalStderrFd >= 0 {
            dup2(originalStderrFd, STDERR_FILENO)
            close(originalStderrFd)
            originalStderrFd = -1
        }

        stdoutPipe = nil
        stderrPipe = nil
        isCapturing = false
        logger.info("GarageXPCOutputCapture stopped capturing.")
    }
}
