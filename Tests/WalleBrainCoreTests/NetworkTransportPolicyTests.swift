import Foundation
import Testing
@testable import WalleBrainCore

struct NetworkTransportPolicyTests {
  @Test
  func standardPolicyUsesSystemProxyBeforeDirectFallback() {
    let policy = NetworkTransportPolicy.standard(requestTimeout: 10, resourceTimeout: 20)

    #expect(policy.urlSessionRoutes.count == 2)
    #expect(policy.urlSessionRoutes[0].bypassesProxy == false)
    #expect(policy.urlSessionRoutes[1].bypassesProxy == true)
  }

  @Test
  func directURLSessionConfigurationDisablesProxyLookup() {
    let configuration = NetworkTransportPolicy.urlSessionConfiguration(
      bypassProxy: true,
      requestTimeout: 10,
      resourceTimeout: 20
    )

    #expect(configuration.connectionProxyDictionary?.isEmpty == true)
  }

  @Test
  func transientStatusClassificationIsShared() {
    #expect(NetworkTransportPolicy.isTransientHTTPStatus(429))
    #expect(NetworkTransportPolicy.isTransientHTTPStatus(500))
    #expect(NetworkTransportPolicy.isTransientHTTPStatus(503))
    #expect(!NetworkTransportPolicy.isTransientHTTPStatus(400))
    #expect(!NetworkTransportPolicy.isTransientHTTPStatus(401))
  }
}
