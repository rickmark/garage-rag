import Foundation
import SwiftUI
import AppKit
import ModelDownloadClient

/// Service managing the state and operations of the ModelDownload XPC service in the macOS app.
@MainActor
final class ModelDownloadService: ObservableObject {
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var statusMessage: String = "Not connected"
    @Published private(set) var activeDownloads: [DownloadTaskInfo] = []
    @Published private(set) var downloadedModels: [DownloadedModelInfo] = []
    @Published private(set) var modelsDirectory: String = ""
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSuccess: String?
    @Published private(set) var logs: [LogLine] = []

    let client: ModelDownloadClient
    private let maxLogLines = 2000
    private var pollTimer: Timer?

    init(client: ModelDownloadClient = ModelDownloadClient()) {
        self.client = client
    }

    deinit {
        pollTimer?.invalidate()
    }

    func appendLog(_ text: String, stream: LogLine.Stream = .stdout) {
        logs.append(LogLine(stream: stream, text: text, source: "model-download-xpc"))
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func clearMessages() {
        lastError = nil
        lastSuccess = nil
    }

    // MARK: - Status & Refresh

    func ping() async -> Bool {
        do {
            let reply = try await client.ping()
            isConnected = true
            statusMessage = reply
            appendLog("Ping reply: \(reply)")
            return true
        } catch {
            isConnected = false
            statusMessage = "Service unavailable"
            lastError = error.localizedDescription
            appendLog("Ping failed: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    func refresh() async {
        do {
            let pingResp = try await client.ping()
            isConnected = true

            let downloads = try await client.listDownloads()
            self.activeDownloads = downloads

            let dir = try await client.getModelsDirectory()
            self.modelsDirectory = dir

            let models = try await client.listDownloadedModels()
            self.downloadedModels = models

            let activeCount = downloads.filter { $0.status == .downloading || $0.status == .queued }.count
            if activeCount > 0 {
                statusMessage = "\(activeCount) download(s) in progress"
                startPollingIfNeeded()
            } else {
                statusMessage = "\(models.count) model(s) available (\(pingResp))"
                stopPollingIfNoActiveDownloads()
            }
        } catch {
            isConnected = false
            statusMessage = "Service unavailable"
            lastError = error.localizedDescription
            appendLog("Failed to refresh model downloader: \(error.localizedDescription)", stream: .stderr)
        }
    }

    // MARK: - Polling for active progress

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollActiveDownloads()
            }
        }
    }

    private func stopPollingIfNoActiveDownloads() {
        let hasActive = activeDownloads.contains { $0.status == .downloading || $0.status == .queued }
        if !hasActive {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func pollActiveDownloads() async {
        guard isConnected else { return }
        if let downloads = try? await client.listDownloads() {
            self.activeDownloads = downloads
            let hasActive = downloads.contains { $0.status == .downloading || $0.status == .queued }
            if !hasActive {
                // Refresh local file list when all downloads finish
                if let models = try? await client.listDownloadedModels() {
                    self.downloadedModels = models
                }
                stopPollingIfNoActiveDownloads()
            }
        }
    }

    // MARK: - Download Actions

    @discardableResult
    func startDownload(item: ModelCatalogItem, authToken: String? = nil) async -> Bool {
        return await startDownload(
            url: item.downloadUrl,
            filename: item.filename,
            modelId: item.id,
            expectedSize: item.sizeBytes,
            authToken: authToken
        )
    }

    @discardableResult
    func startDownload(
        url: String,
        filename: String? = nil,
        modelId: String? = nil,
        expectedSize: Int64? = nil,
        authToken: String? = nil
    ) async -> Bool {
        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUrl.isEmpty else {
            lastError = "Download URL cannot be empty."
            return false
        }

        isBusy = true
        defer { isBusy = false }
        lastError = nil
        lastSuccess = nil

        let req = ModelDownloadRequest(
            url: trimmedUrl,
            filename: filename?.trimmingCharacters(in: .whitespacesAndNewlines),
            modelId: modelId,
            expectedSize: expectedSize,
            authToken: authToken
        )

        do {
            appendLog("Starting download for \(req.filename ?? trimmedUrl)...")
            let taskInfo = try await client.startDownload(request: req)
            lastSuccess = "Started download: \(taskInfo.filename)"
            appendLog("Download task created (ID: \(taskInfo.id)) for \(taskInfo.filename)")
            await refresh()
            startPollingIfNeeded()
            return true
        } catch {
            lastError = error.localizedDescription
            appendLog("Failed to start download: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    @discardableResult
    func cancelDownload(taskId: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            appendLog("Cancelling download task \(taskId)...")
            let success = try await client.cancelDownload(taskId: taskId)
            if success {
                lastSuccess = "Download cancelled."
                appendLog("Download cancelled successfully.")
                await refresh()
                return true
            } else {
                lastError = "Could not cancel download."
                return false
            }
        } catch {
            lastError = error.localizedDescription
            appendLog("Error cancelling download: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    @discardableResult
    func pauseDownload(taskId: String) async -> Bool {
        do {
            let success = try await client.pauseDownload(taskId: taskId)
            if success {
                appendLog("Download \(taskId) paused.")
                await refresh()
            }
            return success
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func resumeDownload(taskId: String) async -> Bool {
        do {
            let success = try await client.resumeDownload(taskId: taskId)
            if success {
                appendLog("Download \(taskId) resumed.")
                await refresh()
                startPollingIfNeeded()
            }
            return success
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteDownloadedModel(_ model: DownloadedModelInfo) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            appendLog("Deleting model file \(model.filename)...")
            let success = try await client.deleteDownloadedModel(at: model.path)
            if success {
                lastSuccess = "Model \(model.filename) deleted."
                appendLog("Deleted model \(model.filename).")
                await refresh()
                return true
            } else {
                lastError = "File not found or could not be deleted."
                return false
            }
        } catch {
            lastError = error.localizedDescription
            appendLog("Failed to delete model: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    // MARK: - Query Helpers

    func isModelDownloaded(filename: String) -> Bool {
        downloadedModels.contains { $0.filename == filename }
    }

    func isModelDownloading(url: String) -> Bool {
        activeDownloads.contains { ($0.url == url || $0.filename == url) && ($0.status == .downloading || $0.status == .queued) }
    }

    func downloadedModel(for filename: String) -> DownloadedModelInfo? {
        downloadedModels.first { $0.filename == filename }
    }

    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    func copyToClipboard(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastSuccess = "Copied to clipboard!"
    }
}
