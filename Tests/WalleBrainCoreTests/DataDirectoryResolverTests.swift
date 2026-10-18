import Foundation
import Testing
@testable import WalleBrainCore

struct DataDirectoryResolverTests {
  private static let repo = "/Users/me/code/WalleBrain"
  private static let applicationSupport = URL(fileURLWithPath: "/Users/me/Library/Application Support/WalleBrain", isDirectory: true)

  private func makeResolver(
    environment: [String: String] = [:],
    storedPath: String? = nil,
    currentDirectory: String = "/",
    bundlePath: String = "/Applications/WalleBrain.app",
    bundledDefaultPath: String? = nil,
    existingPaths: Set<String> = []
  ) -> DataDirectoryResolver {
    DataDirectoryResolver(
      environment: environment,
      storedPath: storedPath,
      currentDirectory: URL(fileURLWithPath: currentDirectory, isDirectory: true),
      bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
      bundledDefaultPath: bundledDefaultPath,
      applicationSupportDirectory: Self.applicationSupport,
      fileExists: { path in
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        return existingPaths.contains(normalized)
      }
    )
  }

  private func path(_ resolved: ResolvedDataDirectory) -> String {
    resolved.url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
  }

  @Test
  func environmentOverrideWinsOverEverything() {
    let resolved = makeResolver(
      environment: ["WALLEBRAIN_BASE_DIR": "/tmp/override"],
      storedPath: "/Volumes/Data/WalleBrain",
      currentDirectory: Self.repo,
      bundlePath: "\(Self.repo)/runtime/native/WalleBrain.app",
      bundledDefaultPath: Self.repo,
      existingPaths: ["\(Self.repo)/Package.swift", "\(Self.repo)/runtime"]
    ).resolve()

    #expect(resolved.source == .environment)
    #expect(path(resolved) == "/tmp/override")
  }

  @Test
  func emptyEnvironmentOverrideIsIgnored() {
    let resolved = makeResolver(
      environment: ["WALLEBRAIN_BASE_DIR": "  "],
      storedPath: "/Volumes/Data/WalleBrain"
    ).resolve()

    #expect(resolved.source == .settings)
  }

  @Test
  func workingDirectoryCheckoutWinsOverSettings() {
    let resolved = makeResolver(
      storedPath: "/Volumes/Data/WalleBrain",
      currentDirectory: Self.repo,
      existingPaths: ["\(Self.repo)/Package.swift"]
    ).resolve()

    #expect(resolved.source == .developmentCheckout)
    #expect(path(resolved) == Self.repo)
  }

  @Test
  func bundleInsideCheckoutRuntimeUsesThatCheckout() {
    let worktree = "/Users/me/code/WalleBrain/.claude/worktrees/feature"
    let resolved = makeResolver(
      storedPath: Self.repo,
      bundlePath: "\(worktree)/runtime/native/WalleBrain.app",
      existingPaths: ["\(worktree)/Package.swift"]
    ).resolve()

    #expect(resolved.source == .developmentCheckout)
    #expect(path(resolved) == worktree)
  }

  @Test
  func bundleOutsideRuntimeNativeIsNotTreatedAsCheckout() {
    // An app copied to <checkout>/dist/ must not be mistaken for a dev bundle.
    let resolved = makeResolver(
      bundlePath: "\(Self.repo)/dist/x/WalleBrain.app",
      existingPaths: ["\(Self.repo)/Package.swift"]
    ).resolve()

    #expect(resolved.source == .applicationSupport)
  }

  @Test
  func installedAppUsesStoredSetting() {
    let resolved = makeResolver(
      storedPath: "~/Documents/WalleBrain Data",
      bundledDefaultPath: Self.repo,
      existingPaths: ["\(Self.repo)/runtime"]
    ).resolve()

    #expect(resolved.source == .settings)
    #expect(path(resolved) == NSString(string: "~/Documents/WalleBrain Data").expandingTildeInPath)
  }

  @Test
  func storedSettingIsUsedEvenWhenMissing() {
    // Never fall back silently to another root: that would hide the meeting list.
    let resolved = makeResolver(storedPath: "/Volumes/Unplugged/WalleBrain").resolve()

    #expect(resolved.source == .settings)
    #expect(path(resolved) == "/Volumes/Unplugged/WalleBrain")
  }

  @Test
  func installedAppFallsBackToBundledRepositoryDefaultWhenItExists() {
    let resolved = makeResolver(
      bundledDefaultPath: Self.repo,
      existingPaths: ["\(Self.repo)/runtime"]
    ).resolve()

    #expect(resolved.source == .bundledDefault)
    #expect(path(resolved) == Self.repo)
  }

  @Test
  func missingBundledDefaultFallsBackToApplicationSupport() {
    let resolved = makeResolver(bundledDefaultPath: Self.repo).resolve()

    #expect(resolved.source == .applicationSupport)
    #expect(path(resolved) == path(ResolvedDataDirectory(url: Self.applicationSupport, source: .applicationSupport)))
  }

  @Test
  func freshInstallUsesApplicationSupport() {
    let resolved = makeResolver().resolve()

    #expect(resolved.source == .applicationSupport)
    #expect(path(resolved) == "/Users/me/Library/Application Support/WalleBrain")
  }

  @Test
  func firstLaunchRecordsDefaultSoItStaysStable() {
    let (defaults, cleanup) = makeDefaults()
    defer { cleanup() }
    let store = DataDirectorySettingsStore(defaults: defaults)

    let first = store.resolveAndRecordDefault(
      using: makeResolver(bundledDefaultPath: Self.repo, existingPaths: ["\(Self.repo)/runtime"])
    )
    #expect(first.source == .bundledDefault)

    // Even if the repository runtime later disappears, the recorded choice is kept.
    var later = makeResolver(bundledDefaultPath: Self.repo)
    later.storedPath = store.storedPath()
    let second = later.resolve()
    #expect(second.source == .settings)
    #expect(path(second) == Self.repo)
  }

  @Test
  func developmentAndEnvironmentRootsAreNotRecorded() {
    let (defaults, cleanup) = makeDefaults()
    defer { cleanup() }
    let store = DataDirectorySettingsStore(defaults: defaults)

    _ = store.resolveAndRecordDefault(using: makeResolver(environment: ["WALLEBRAIN_BASE_DIR": "/tmp/override"]))
    _ = store.resolveAndRecordDefault(
      using: makeResolver(
        bundlePath: "\(Self.repo)/runtime/native/WalleBrain.app",
        existingPaths: ["\(Self.repo)/Package.swift"]
      )
    )

    #expect(store.storedPath() == nil)
  }

  @Test
  func existingSettingIsNotOverwrittenByDefault() {
    let (defaults, cleanup) = makeDefaults()
    defer { cleanup() }
    let store = DataDirectorySettingsStore(defaults: defaults)
    store.save(URL(fileURLWithPath: "/Volumes/Data/WalleBrain", isDirectory: true))

    var resolver = makeResolver()
    resolver.storedPath = store.storedPath()
    let resolved = store.resolveAndRecordDefault(using: resolver)

    #expect(resolved.source == .settings)
    #expect(store.storedPath()?.trimmingSuffix("/") == "/Volumes/Data/WalleBrain")
  }

  @Test
  func runtimePathsHangOffTheResolvedRoot() {
    let paths = RuntimePaths(baseDirectory: Self.applicationSupport)

    #expect(
      paths.nativeMeetingSessionsDirectory.path(percentEncoded: false).trimmingSuffix("/")
        == "/Users/me/Library/Application Support/WalleBrain/runtime/native/MeetingSessions"
    )
  }

  private func makeDefaults() -> (UserDefaults, () -> Void) {
    let suiteName = "WalleBrain.DataDirectoryResolverTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
  }
}

private extension String {
  func trimmingSuffix(_ suffix: String) -> String {
    hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
  }
}
