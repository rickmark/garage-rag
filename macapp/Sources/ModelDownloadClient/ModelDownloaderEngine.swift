import Foundation

/// Core engine managing model downloads, file system storage, and task tracking.
public final class ModelDownloaderEngine: NSObject, @unchecked Sendable {
    public static let shared = ModelDownloaderEngine()

    private let lock = NSLock()
    private var customModelsDirectory: URL?

    private var tasks: [String: DownloadTaskInfo] = [:]
    private var urlTasks: [String: URLSessionDownloadTask] = [:]
    private var lastBytesWritten: [String: (bytes: Int64, timestamp: Date)] = [:]
    private var session: URLSession!

    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 86400.0 // 24 hours for large multi-GB models
        config.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public var defaultModelsDirectory: URL {
        if let custom = customModelsDirectory {
            return custom
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let modelsDir = base.appendingPathComponent("GarageApp", isDirectory: true).appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return modelsDir
    }

    public func setModelsDirectory(path: String) throws {
        let dirUrl = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dirUrl, withIntermediateDirectories: true)
        lock.lock()
        customModelsDirectory = dirUrl
        lock.unlock()
    }

    public func getModelsDirectoryPath() -> String {
        lock.lock()
        defer { lock.unlock() }
        return defaultModelsDirectory.path
    }

    // MARK: - Download Management

    public func startDownload(request: ModelDownloadRequest) throws -> DownloadTaskInfo {
        guard let url = URL(string: request.url), url.scheme == "http" || url.scheme == "https" else {
            throw NSError(domain: "ModelDownloaderEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid download URL: \(request.url)"])
        }

        let filename: String
        if let reqFilename = request.filename, !reqFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filename = reqFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let lastComponent = url.lastPathComponent
            filename = lastComponent.isEmpty ? "model-\(UUID().uuidString.prefix(8)).gguf" : lastComponent
        }

        let targetDir: URL
        if let customDir = request.destinationDirectory, !customDir.isEmpty {
            targetDir = URL(fileURLWithPath: customDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } else {
            targetDir = defaultModelsDirectory
        }

        let destinationFile = targetDir.appendingPathComponent(filename)
        let taskId = UUID().uuidString

        var urlRequest = URLRequest(url: url)
        if let token = request.authToken, !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("Garage-ModelDownloader/1.0", forHTTPHeaderField: "User-Agent")

        let downloadTask = session.downloadTask(with: urlRequest)

        let taskInfo = DownloadTaskInfo(
            id: taskId,
            url: request.url,
            filename: filename,
            destinationPath: destinationFile.path,
            status: .downloading,
            bytesDownloaded: 0,
            totalBytes: request.expectedSize ?? 0,
            fractionCompleted: 0.0,
            bytesPerSecond: 0.0,
            createdAt: Date(),
            updatedAt: Date()
        )

        lock.lock()
        tasks[taskId] = taskInfo
        urlTasks[taskId] = downloadTask
        lastBytesWritten[taskId] = (0, Date())
        lock.unlock()

        downloadTask.taskDescription = taskId
        downloadTask.resume()

        return taskInfo
    }

    public func cancelDownload(taskId: String) -> Bool {
        lock.lock()
        guard var info = tasks[taskId] else {
            lock.unlock()
            return false
        }
        let urlTask = urlTasks[taskId]
        info.status = .cancelled
        info.updatedAt = Date()
        tasks[taskId] = info
        urlTasks.removeValue(forKey: taskId)
        lastBytesWritten.removeValue(forKey: taskId)
        lock.unlock()

        urlTask?.cancel()
        return true
    }

    public func pauseDownload(taskId: String) -> Bool {
        lock.lock()
        guard var info = tasks[taskId], info.status == .downloading else {
            lock.unlock()
            return false
        }
        let urlTask = urlTasks[taskId]
        info.status = .paused
        info.updatedAt = Date()
        tasks[taskId] = info
        lock.unlock()

        urlTask?.suspend()
        return true
    }

    public func resumeDownload(taskId: String) -> Bool {
        lock.lock()
        guard var info = tasks[taskId], info.status == .paused else {
            lock.unlock()
            return false
        }
        let urlTask = urlTasks[taskId]
        info.status = .downloading
        info.updatedAt = Date()
        tasks[taskId] = info
        lock.unlock()

        urlTask?.resume()
        return true
    }

    public func getDownloadStatus(taskId: String) -> DownloadTaskInfo? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[taskId]
    }

    public func listDownloads() -> [DownloadTaskInfo] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tasks.values).sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Downloaded Model Files on Disk

    public func listDownloadedModels(directoryPath: String? = nil) -> [DownloadedModelInfo] {
        let dirUrl: URL
        if let dir = directoryPath, !dir.isEmpty {
            dirUrl = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            dirUrl = defaultModelsDirectory
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(at: dirUrl, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        let supportedExtensions: Set<String> = ["gguf", "bin", "safetensors", "pt", "onnx"]

        var results: [DownloadedModelInfo] = []
        for fileUrl in contents {
            let ext = fileUrl.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) || fileUrl.lastPathComponent.contains(".gguf") else {
                continue
            }

            let values = try? fileUrl.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            let size = Int64(values?.fileSize ?? 0)
            let modDate = values?.contentModificationDate ?? Date()
            let filename = fileUrl.lastPathComponent
            let name = fileUrl.deletingPathExtension().lastPathComponent

            let modelInfo = DownloadedModelInfo(
                name: name,
                filename: filename,
                path: fileUrl.path,
                size: size,
                modifiedAt: modDate,
                format: ext.isEmpty ? "gguf" : ext
            )
            results.append(modelInfo)
        }

        return results.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func deleteDownloadedModel(filePath: String) throws -> Bool {
        let fileUrl = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
            return false
        }
        try FileManager.default.removeItem(at: fileUrl)
        return true
    }

    // MARK: - JSON Helpers for XPC

    public func serialize<T: Encodable>(_ value: T) -> String? {
        guard let data = try? jsonEncoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deserialize<T: Decodable>(_ type: T.Type, from jsonString: String) throws -> T {
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "ModelDownloaderEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])
        }
        return try jsonDecoder.decode(type, from: data)
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloaderEngine: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let taskId = downloadTask.taskDescription else { return }

        lock.lock()
        guard var info = tasks[taskId] else {
            lock.unlock()
            return
        }

        let now = Date()
        let previous = lastBytesWritten[taskId] ?? (bytes: 0, timestamp: now)
        let elapsed = now.timeIntervalSince(previous.timestamp)

        var speed = info.bytesPerSecond
        if elapsed >= 0.5 {
            let bytesDelta = totalBytesWritten - previous.bytes
            speed = Double(bytesDelta) / elapsed
            lastBytesWritten[taskId] = (totalBytesWritten, now)
        }

        info.bytesDownloaded = totalBytesWritten
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (info.totalBytes > 0 ? info.totalBytes : totalBytesWritten)
        info.totalBytes = total
        info.fractionCompleted = total > 0 ? min(1.0, max(0.0, Double(totalBytesWritten) / Double(total))) : 0.0
        info.bytesPerSecond = speed

        if speed > 0 && total > totalBytesWritten {
            info.estimatedTimeRemaining = Double(total - totalBytesWritten) / speed
        }

        info.updatedAt = now
        tasks[taskId] = info
        lock.unlock()
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let taskId = downloadTask.taskDescription else { return }

        lock.lock()
        guard var info = tasks[taskId] else {
            lock.unlock()
            return
        }
        lock.unlock()

        let destUrl = URL(fileURLWithPath: info.destinationPath)
        do {
            // Remove existing file if present
            if FileManager.default.fileExists(atPath: destUrl.path) {
                try FileManager.default.removeItem(at: destUrl)
            }
            try FileManager.default.createDirectory(at: destUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destUrl)

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: destUrl.path)[.size] as? Int64) ?? info.bytesDownloaded

            lock.lock()
            info.status = .completed
            info.bytesDownloaded = fileSize
            info.totalBytes = fileSize
            info.fractionCompleted = 1.0
            info.bytesPerSecond = 0.0
            info.estimatedTimeRemaining = 0.0
            info.updatedAt = Date()
            tasks[taskId] = info
            urlTasks.removeValue(forKey: taskId)
            lastBytesWritten.removeValue(forKey: taskId)
            lock.unlock()
        } catch {
            lock.lock()
            info.status = .failed
            info.errorMessage = error.localizedDescription
            info.updatedAt = Date()
            tasks[taskId] = info
            urlTasks.removeValue(forKey: taskId)
            lastBytesWritten.removeValue(forKey: taskId)
            lock.unlock()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let taskId = task.taskDescription else { return }
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            lock.lock()
            if var info = tasks[taskId] {
                info.status = .failed
                info.errorMessage = error.localizedDescription
                info.updatedAt = Date()
                tasks[taskId] = info
            }
            urlTasks.removeValue(forKey: taskId)
            lastBytesWritten.removeValue(forKey: taskId)
            lock.unlock()
        }
    }
}
