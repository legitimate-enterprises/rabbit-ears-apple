import Foundation

/// Fetches one file of a download to the device. The app's goes through
/// URLSession, in the background on iOS; tests pass their own.
public protocol Downloader: Sendable {
    /// `progress` takes the share fetched. Throws `DownloadFailure`.
    func fetch(
        _ request: URLRequest, to destination: URL, resumeData: Data?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
    /// Stops every transfer, those a process before this one started included.
    func cancelAll()
}

/// Why a fetch stopped: the server's status, with its message, or the
/// connection dropping, with what lets the next try carry on where this one
/// stopped.
public enum DownloadFailure: Error, Equatable {
    case status(Int, message: String? = nil)
    case interrupted(resumeData: Data?)
}

/// URLSession's download tasks, which resume by the server's validators.
/// With a background configuration the system carries transfers on while
/// the app is suspended or not running; one it finishes for a relaunched
/// app lands where its task description says, and a fetch for a
/// destination a transfer is already headed to joins it.
public final class URLSessionDownloader: NSObject, Downloader, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Waiter {
        let progress: @Sendable (Double) -> Void
        let done: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    /// By destination path: the fetches waiting on its transfer.
    private var waiting: [String: [Waiter]] = [:]
    /// By destination path: how a transfer no fetch waited on ended.
    private var ended: [String: Result<Void, DownloadFailure>] = [:]
    private var finishEvents: (@Sendable () -> Void)?
    private var session: URLSession!

    /// `background` names a background session, as iOS needs; nil downloads
    /// in the app's own process. `wait` bounds a request the server holds
    /// with nothing sent while it converts; one that runs out asks again.
    public init(background identifier: String? = nil, wait: TimeInterval = 3600) {
        super.init()
        let configuration =
            identifier.map {
                let configuration = URLSessionConfiguration.background(withIdentifier: $0)
                configuration.sessionSendsLaunchEvents = true
                configuration.isDiscretionary = false
                return configuration
            } ?? .default
        configuration.timeoutIntervalForRequest = wait
        // A claim outlives its conversion by 3 days, so a transfer may take as long.
        configuration.timeoutIntervalForResource = 3 * 24 * 3600
        // Low Data Mode always waits, even for a transfer the system carries while the app is suspended.
        configuration.allowsConstrainedNetworkAccess = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Keeps the system's handler from a background relaunch until its events are in.
    public func handleEvents(_ completion: @escaping @Sendable () -> Void) {
        lock.withLock { finishEvents = completion }
    }

    public func fetch(
        _ request: URLRequest, to destination: URL, resumeData: Data?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let path = destination.path(percentEncoded: false)
        let running = await session.allTasks.contains {
            $0.taskDescription == path && ($0.state == .running || $0.state == .suspended)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let early: Result<Void, DownloadFailure>? = lock.withLock {
                    // A file an ended transfer landed counts only while it is still there.
                    if let result = ended.removeValue(forKey: path),
                        (try? result.get()) == nil || FileManager.default.fileExists(atPath: path)
                    {
                        return result
                    }
                    waiting[path, default: []].append(Waiter(progress: progress, done: continuation))
                    return nil
                }
                if let early { return continuation.resume(with: early.mapError { $0 as any Error }) }
                guard !running else { return }
                let task =
                    resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
                task.taskDescription = path
                task.resume()
            }
        } onCancel: {
            session.getAllTasks { tasks in
                for task in tasks where task.taskDescription == path { task.cancel() }
            }
        }
    }

    public func cancelAll() {
        session.getAllTasks { tasks in
            for task in tasks { task.cancel() }
        }
    }

    /// Hands how a destination's transfer ended to the fetches waiting on it, or keeps it for the next.
    private func end(_ path: String, _ result: Result<Void, DownloadFailure>) {
        let waiters: [Waiter] = lock.withLock {
            guard let waiters = waiting.removeValue(forKey: path) else {
                ended[path] = result
                return []
            }
            return waiters
        }
        for waiter in waiters { waiter.done.resume(with: result.mapError { $0 as any Error }) }
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let path = downloadTask.taskDescription else { return }
        let waiters = lock.withLock { waiting[path] ?? [] }
        for waiter in waiters { waiter.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    /// The file must move before this returns, when URLSession deletes it.
    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard let path = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // A proxy in front cut the server's hold short, as Cloudflare does at 100 seconds: ask again.
        if status == 504 || status == 524 { return again(downloadTask, in: session, to: path, after: 5) }
        guard (200..<300).contains(status) else {
            // The server's error body says why, as a failed conversion's message.
            let body = (try? Data(contentsOf: location)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            return end(path, .failure(.status(status, message: (body as? [String: Any])?["message"] as? String)))
        }
        let destination = URL(filePath: path)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            end(path, .success(()))
        } catch {
            end(path, .failure(.interrupted(resumeData: nil)))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let path = task.taskDescription else { return }
        let code = (error as? URLError)?.code
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        // The server held the request past the wait with nothing sent: ask again, so a suspended app need not.
        if code == .timedOut, resume == nil { return again(task, in: session, to: path) }
        if code == .cancelled, lock.withLock({ waiting[path] == nil }) { return }
        end(path, .failure(.interrupted(resumeData: resume)))
    }

    /// A delay keeps a proxy that refuses at once from turning the retry into a tight loop.
    private func again(_ task: URLSessionTask, in session: URLSession, to path: String, after delay: TimeInterval = 0) {
        guard let request = task.originalRequest else { return end(path, .failure(.interrupted(resumeData: nil))) }
        let again = session.downloadTask(with: request)
        again.taskDescription = path
        if delay > 0 { again.earliestBeginDate = Date().addingTimeInterval(delay) }
        again.resume()
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let finish = lock.withLock {
            defer { finishEvents = nil }
            return finishEvents
        }
        DispatchQueue.main.async { finish?() }
    }
}
