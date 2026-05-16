import Foundation

public struct NetworkTransportPolicy: Sendable {
  public struct URLSessionRoute: Sendable {
    public let label: String
    public let bypassesProxy: Bool
    public let urlSession: URLSession
  }

  public static let maximumRequestAttempts = 3
  public static let retryDelays: [Duration] = [.seconds(2), .seconds(8)]

  public let urlSessionRoutes: [URLSessionRoute]

  public init(urlSessionRoutes: [URLSessionRoute]) {
    self.urlSessionRoutes = urlSessionRoutes
  }

  public static func llmDefault() -> NetworkTransportPolicy {
    standard(requestTimeout: 900, resourceTimeout: 1_800)
  }

  public static func realtimeDefault() -> NetworkTransportPolicy {
    standard(requestTimeout: 60, resourceTimeout: 3_600)
  }

  public static func standard(
    requestTimeout: TimeInterval,
    resourceTimeout: TimeInterval,
    waitsForConnectivity: Bool = true
  ) -> NetworkTransportPolicy {
    NetworkTransportPolicy(urlSessionRoutes: [
      URLSessionRoute(
        label: "system proxy URLSession",
        bypassesProxy: false,
        urlSession: urlSession(
          bypassProxy: false,
          requestTimeout: requestTimeout,
          resourceTimeout: resourceTimeout,
          waitsForConnectivity: waitsForConnectivity
        )
      ),
      URLSessionRoute(
        label: "direct URLSession",
        bypassesProxy: true,
        urlSession: urlSession(
          bypassProxy: true,
          requestTimeout: requestTimeout,
          resourceTimeout: resourceTimeout,
          waitsForConnectivity: waitsForConnectivity
        )
      ),
    ])
  }

  public static func singleURLSession(_ urlSession: URLSession, label: String = "injected URLSession") -> NetworkTransportPolicy {
    NetworkTransportPolicy(urlSessionRoutes: [
      URLSessionRoute(label: label, bypassesProxy: false, urlSession: urlSession),
    ])
  }

  public static func urlSession(
    bypassProxy: Bool,
    requestTimeout: TimeInterval,
    resourceTimeout: TimeInterval,
    waitsForConnectivity: Bool = true
  ) -> URLSession {
    URLSession(configuration: urlSessionConfiguration(
      bypassProxy: bypassProxy,
      requestTimeout: requestTimeout,
      resourceTimeout: resourceTimeout,
      waitsForConnectivity: waitsForConnectivity
    ))
  }

  public static func urlSessionConfiguration(
    bypassProxy: Bool,
    requestTimeout: TimeInterval,
    resourceTimeout: TimeInterval,
    waitsForConnectivity: Bool = true
  ) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = resourceTimeout
    configuration.waitsForConnectivity = waitsForConnectivity
    if bypassProxy {
      configuration.connectionProxyDictionary = [:]
    }
    return configuration
  }

  public static func isTransientHTTPStatus(_ statusCode: Int) -> Bool {
    statusCode == 408
      || statusCode == 409
      || statusCode == 425
      || statusCode == 429
      || (500..<600).contains(statusCode)
  }

  public static func sleepBeforeRetry(attempt: Int) async throws {
    let index = max(0, min(attempt - 1, retryDelays.count - 1))
    try await Task.sleep(for: retryDelays[index])
  }
}
