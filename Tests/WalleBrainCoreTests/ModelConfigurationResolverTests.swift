import Testing
@testable import WalleBrainCore

struct ModelConfigurationResolverTests {
  @Test
  func resolvesEnvironmentReferences() throws {
    let resolver = ModelConfigurationResolver(
      environment: [
        "DEERAPI_BASE_URL": "https://example.com/v1",
        "DEERAPI_KEY": "secret-key",
        "WALLEBRAIN_MODELS": " gemini-3.1-flash, gemini-3-flash-preview , gemini-3.1-flash, gemini-2.5-flash ",
      ]
    )

    let configuration = ModelConfiguration(
      baseURLReference: "$DEERAPI_BASE_URL",
      apiKeyReference: "$DEERAPI_KEY",
      modelsReference: "$WALLEBRAIN_MODELS"
    )

    let resolved = try resolver.resolve(configuration)

    #expect(resolved.baseURL == "https://example.com/v1")
    #expect(resolved.apiKey == "secret-key")
    #expect(resolved.models == ["gemini-3.1-flash", "gemini-3-flash-preview", "gemini-2.5-flash"])
  }

  @Test
  func previewFlagsMissingEnvironmentVariable() {
    let resolver = ModelConfigurationResolver(mergedEnvironment: [:])
    let configuration = ModelConfiguration(
      baseURLReference: "$DEERAPI_BASE_URL",
      apiKeyReference: "$DEERAPI_KEY",
      modelsReference: "gemini-3-flash-preview"
    )

    let preview = resolver.preview(for: configuration)

    #expect(preview.baseURL.errorMessage == "Environment variable DEERAPI_BASE_URL is not set.")
    #expect(preview.apiKey.errorMessage == "Environment variable DEERAPI_KEY is not set.")
    #expect(preview.models.errorMessage == nil)
    #expect(preview.resolvedModels == ["gemini-3-flash-preview"])
    #expect(preview.isValid == false)
  }
}
