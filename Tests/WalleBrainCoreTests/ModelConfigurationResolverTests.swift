import Testing
@testable import WalleBrainCore

struct ModelConfigurationResolverTests {
  @Test
  func resolvesEnvironmentReferences() throws {
    let resolver = ModelConfigurationResolver(
      environment: [
        "WALLEBRAIN_LLM_BASE_URL": "https://example.com/v1",
        "WALLEBRAIN_LLM_API_KEY": "secret-key",
        "WALLEBRAIN_LLM_MODELS": " model-a, model-b , model-a, model-c ",
      ]
    )

    let configuration = ModelConfiguration(
      baseURLReference: "$WALLEBRAIN_LLM_BASE_URL",
      apiKeyReference: "$WALLEBRAIN_LLM_API_KEY",
      modelsReference: "$WALLEBRAIN_LLM_MODELS"
    )

    let resolved = try resolver.resolve(configuration)

    #expect(resolved.baseURL == "https://example.com/v1")
    #expect(resolved.apiKey == "secret-key")
    #expect(resolved.models == ["model-a", "model-b", "model-c"])
    #expect(resolved.providerLabel == "OpenAI-compatible")
  }

  @Test
  func previewFlagsMissingEnvironmentVariable() {
    let resolver = ModelConfigurationResolver(mergedEnvironment: [:])
    let configuration = ModelConfiguration(
      baseURLReference: "$WALLEBRAIN_LLM_BASE_URL",
      apiKeyReference: "$WALLEBRAIN_LLM_API_KEY",
      modelsReference: "model-a"
    )

    let preview = resolver.preview(for: configuration)

    #expect(preview.baseURL.errorMessage == "Environment variable WALLEBRAIN_LLM_BASE_URL is not set.")
    #expect(preview.apiKey.errorMessage == "Environment variable WALLEBRAIN_LLM_API_KEY is not set.")
    #expect(preview.models.errorMessage == nil)
    #expect(preview.providerLabel.resolvedValue == "OpenAI-compatible")
    #expect(preview.resolvedModels == ["model-a"])
    #expect(preview.isValid == false)
  }

  @Test
  func resolvesLegacyEnvironmentFallbacksForDefaultReferences() throws {
    let resolver = ModelConfigurationResolver(
      mergedEnvironment: [
        "DEERAPI_BASE_URL": "https://legacy.example.com/v1",
        "DEERAPI_KEY": "legacy-secret",
        "OPENAI_MODEL": "legacy-model",
      ]
    )

    let resolved = try resolver.resolve(ModelConfiguration())

    #expect(resolved.baseURL == "https://legacy.example.com/v1")
    #expect(resolved.apiKey == "legacy-secret")
    #expect(resolved.models == ["legacy-model"])
  }
}
