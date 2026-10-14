import Foundation

/// An opt-in `URLProtocol` that records, for each HTTP request it sees, the method, the URL without
/// its query string or fragment, the status and the time it took. No bodies, no headers.
///
/// IT ONLY SEES WHAT IS ROUTED THROUGH IT. `OverblastFeedback.recordNetwork()` registers it with
/// `URLProtocol.registerClass`, which covers `URLSession.shared`; a session you configure yourself
/// needs `OverblastNetworkRecorder.install(in:)` on its configuration before the session is made.
/// Traffic from WebKit, from a third-party SDK's private session, from `Network.framework` or from a
/// socket library is not seen at all.
///
/// It forwards every request through a session of its own and passes the answer back unchanged,
/// streaming included. Two things change: authentication challenges get the system's default
/// handling (your session delegate's `didReceive challenge` is not called for recorded requests), and
/// redirects are handed back to the original session to follow. Leave it off in an app that pins
/// certificates in a session delegate.
public final class OverblastNetworkRecorder: URLProtocol, @unchecked Sendable {
  // @unchecked: URLProtocol instances are driven by the loading system on one thread per request;
  // the only state shared between them is in `Forwarder`, behind its lock.

  static let handledKey = "network.deployd.overblast-feedback.recorded"
  /// What the recorder writes into. `OverblastFeedback` reads it when a report is built.
  public static let entries = RingBuffer<FeedbackNetworkEntry>(capacity: FeedbackLimits.networkEntries)

  /// Adds the recorder to a session configuration you build yourself. Call before making the session.
  public static func install(in configuration: URLSessionConfiguration) {
    var classes = configuration.protocolClasses ?? []
    if !classes.contains(where: { $0 == OverblastNetworkRecorder.self }) {
      classes.insert(OverblastNetworkRecorder.self, at: 0)
    }
    configuration.protocolClasses = classes
  }

  private var dataTask: URLSessionDataTask?
  private var startedAt = Date()

  override public class func canInit(with request: URLRequest) -> Bool {
    guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
    // Never the report itself, and never a request this recorder already forwarded.
    if request.value(forHTTPHeaderField: FeedbackClient.keyHeader) != nil { return false }
    return URLProtocol.property(forKey: handledKey, in: request) == nil
  }

  override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override public func startLoading() {
    guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
      client?.urlProtocol(self, didFailWithError: URLError(.unknown))
      return
    }
    URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
    startedAt = Date()
    let task = Forwarder.shared.session.dataTask(with: mutable as URLRequest)
    Forwarder.shared.register(task, for: self)
    dataTask = task
    task.resume()
  }

  override public func stopLoading() {
    dataTask?.cancel()
  }

  fileprivate func finish(status: Int) {
    guard let url = request.url else { return }
    let ms = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
    Self.entries.append(FeedbackNetworkEntry(
      t: Int64((startedAt.timeIntervalSince1970 * 1000).rounded()),
      method: (request.httpMethod ?? "GET").uppercased(),
      url: FeedbackText.strippedURL(url),
      status: status,
      ms: ms
    ))
  }

  /// One session and one delegate for every recorded request, mapping tasks back to the protocol
  /// instance that owns them.
  private final class Forwarder: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // @unchecked: `owners` is only touched under `lock`.
    static let shared = Forwarder()
    private let lock = NSLock()
    private var owners: [Int: OverblastNetworkRecorder] = [:]
    private var statuses: [Int: Int] = [:]

    lazy var session: URLSession = {
      let config = URLSessionConfiguration.default
      // Not this class again, or every request would loop through it.
      config.protocolClasses = (config.protocolClasses ?? []).filter { $0 != OverblastNetworkRecorder.self }
      return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func register(_ task: URLSessionTask, for owner: OverblastNetworkRecorder) {
      lock.lock()
      owners[task.taskIdentifier] = owner
      lock.unlock()
    }

    private func owner(_ task: URLSessionTask) -> OverblastNetworkRecorder? {
      lock.lock()
      defer { lock.unlock() }
      return owners[task.taskIdentifier]
    }

    private func release(_ task: URLSessionTask) -> (OverblastNetworkRecorder?, Int) {
      lock.lock()
      defer { lock.unlock() }
      let owner = owners.removeValue(forKey: task.taskIdentifier)
      let status = statuses.removeValue(forKey: task.taskIdentifier) ?? 0
      return (owner, status)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
      if let http = response as? HTTPURLResponse {
        lock.lock()
        statuses[dataTask.taskIdentifier] = http.statusCode
        lock.unlock()
      }
      if let owner = owner(dataTask) {
        owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .allowed)
      }
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      if let owner = owner(dataTask) {
        owner.client?.urlProtocol(owner, didLoad: data)
      }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
      // Hand the redirect back to the caller's session, which re-issues it (and records it as its
      // own request); this task stops here, as Apple's CustomHTTPProtocol sample does it.
      let (owner, _) = release(task)
      if let owner {
        owner.finish(status: response.statusCode)
        var redirected = request
        if let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest {
          URLProtocol.removeProperty(forKey: OverblastNetworkRecorder.handledKey, in: mutable)
          redirected = mutable as URLRequest
        }
        owner.client?.urlProtocol(owner, wasRedirectedTo: redirected, redirectResponse: response)
        task.cancel()
        owner.client?.urlProtocol(owner, didFailWithError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
      }
      completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      let (owner, status) = release(task)
      guard let owner else { return }
      owner.finish(status: status)
      if let error {
        owner.client?.urlProtocol(owner, didFailWithError: error)
      } else {
        owner.client?.urlProtocolDidFinishLoading(owner)
      }
    }
  }
}
