import Foundation
import Testing
@testable import WalleBrainCore

struct ModelConfigurationStoreTests {
  @Test
  func migratesLegacySingleModelDefaultToNewDefaultChain() {
    let suiteName = "WalleBrain.ModelConfigurationStoreTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Failed to create isolated UserDefaults suite.")
      return
    }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set(
      ModelConfiguration.legacyDefaultModelsReference,
      forKey: "WalleBrain.ModelConfiguration.modelsReference"
    )

    let loaded = ModelConfigurationStore(defaults: defaults).load()

    #expect(loaded.modelsReference == ModelConfiguration.defaultModelsReference)
  }

  @Test
  func preservesExplicitCustomModelChain() {
    let suiteName = "WalleBrain.ModelConfigurationStoreTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Failed to create isolated UserDefaults suite.")
      return
    }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let customChain = "gemini-3.1-pro-preview, gemini-3-flash-preview"
    defaults.set(customChain, forKey: "WalleBrain.ModelConfiguration.modelsReference")

    let loaded = ModelConfigurationStore(defaults: defaults).load()

    #expect(loaded.modelsReference == customChain)
  }
}
