import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class SyncV3HTTP: SyncV3Transport, @unchecked Sendable {
    public let endpoint: URL
    public init(endpoint: String, allowLoopbackHTTP: Bool = false) throws {
        guard let c = URLComponents(string: endpoint), let url = c.url, let host = c.host,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.scheme == "https" || (allowLoopbackHTTP && c.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else { throw SyncV3Error.invalidRequest }
        self.endpoint = url
    }
    public func request(method: String, path: String, body: Data?, token: String?) async throws -> Data {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains(".."),
              let url = URL(string: endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { throw SyncV3Error.invalidRequest }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 30; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { guard token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw SyncV3Error.invalidRequest }; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let operation = BoundedV3Request()
        let (data, status) = try await withTaskCancellationHandler(operation: { try await operation.send(request) }, onCancel: { operation.cancel() })
        guard (200..<300).contains(status) else {
            struct Failure: Decodable { struct Detail: Decodable { var code: String }; var error: Detail }
            if let error = try? DocumentCodec.decode(Failure.self, from: data), let code = SyncV3Error(rawValue: error.error.code) { throw code }
            if status == 401 || status == 403 { throw SyncV3Error.authenticationRequired }
            if status == 429 { throw SyncV3Error.quotaUnavailable }
            throw SyncV3Error.storageUnavailable
        }
        return data
    }
}
private final class BoundedV3Request: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, Int), Error>?
    private var body = Data()
    private var status = 0
    private var cancelled = false
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false; config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session; let task = session.dataTask(with: request); self.task = task
            lock.unlock(); task.resume()
        }
    }
    func cancel() { lock.lock(); cancelled = true; let task = self.task; lock.unlock(); task?.cancel() }
    private func finish(_ error: Error? = nil) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil
        let result = (body, status), session = self.session; self.session = nil; lock.unlock()
        session?.finishTasksAndInvalidate()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume(returning: result) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= 2 * 1024 * 1024 else { completionHandler(.cancel); finish(SyncV3Error.corruptData); return }
        status = http.statusCode; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= 2 * 1024 * 1024 else { dataTask.cancel(); finish(SyncV3Error.corruptData); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error) }
}
