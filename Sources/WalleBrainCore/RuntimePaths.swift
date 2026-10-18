import Foundation

public struct RuntimePaths: Sendable {
  public let baseDirectory: URL

  public init(baseDirectory: URL = Self.defaultBaseDirectory()) {
    self.baseDirectory = baseDirectory
  }

  public var runtimeDirectory: URL {
    baseDirectory.appending(path: "runtime", directoryHint: .isDirectory)
  }

  public var nativeDirectory: URL {
    runtimeDirectory.appending(path: "native", directoryHint: .isDirectory)
  }

  public var dictionaryDirectory: URL {
    nativeDirectory.appending(path: "Dictionary", directoryHint: .isDirectory)
  }

  public var speechAssetsDirectory: URL {
    nativeDirectory.appending(path: "SpeechAssets", directoryHint: .isDirectory)
  }

  public var nativeMeetingSessionsDirectory: URL {
    nativeDirectory.appending(path: "MeetingSessions", directoryHint: .isDirectory)
  }

  public var nativeMeetingAudioDirectory: URL {
    nativeDirectory.appending(path: "MeetingAudio", directoryHint: .isDirectory)
  }

  public var nativeAcceptanceDirectory: URL {
    runtimeDirectory.appending(path: "acceptance/native", directoryHint: .isDirectory)
  }

  public var dictionaryFile: URL {
    dictionaryDirectory.appending(path: "Business Dictionary.md", directoryHint: .notDirectory)
  }

  public var correctionMemoryFile: URL {
    dictionaryDirectory.appending(path: "Correction Memory.json", directoryHint: .notDirectory)
  }

  public var obsidianMeetingsDirectory: URL {
    runtimeDirectory.appending(path: "Obsidian/Meetings/Native", directoryHint: .isDirectory)
  }

  public func sessionJSONURL(fileStem: String) -> URL {
    nativeMeetingSessionsDirectory.appending(path: "\(fileStem).session.json", directoryHint: .notDirectory)
  }

  public func sessionMarkdownURL(fileStem: String) -> URL {
    nativeMeetingSessionsDirectory.appending(path: "\(fileStem).session.md", directoryHint: .notDirectory)
  }

  public func audioRecordingURL(fileStem: String) -> URL {
    nativeMeetingAudioDirectory.appending(path: "\(fileStem).caf", directoryHint: .notDirectory)
  }

  public func fixtureAudioURL(named fileName: String) -> URL {
    baseDirectory.appending(path: "fixtures/datasets/magicdata_dev_subset/\(fileName)", directoryHint: .notDirectory)
  }

  public func ensureDirectories() throws {
    try FileManager.default.createDirectory(at: dictionaryDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: speechAssetsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nativeMeetingSessionsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nativeMeetingAudioDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nativeAcceptanceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: obsidianMeetingsDirectory, withIntermediateDirectories: true)
  }

  public static func defaultBaseDirectory() -> URL {
    DataDirectoryResolver.live().resolve().url
  }
}

/// Where the data root came from. Listed in resolution order.
public enum DataDirectorySource: String, Sendable, Equatable {
  /// `WALLEBRAIN_BASE_DIR` is set.
  case environment
  /// Running from a source checkout: the working directory holds `Package.swift`,
  /// or the app bundle sits at `<checkout>/runtime/native/<name>.app`.
  case developmentCheckout
  /// The user's choice, stored in settings.
  case settings
  /// The default baked into the installed bundle (the repository runtime that existed at install time).
  case bundledDefault
  /// Fresh install with nothing else configured.
  case applicationSupport

  /// Whether the Settings choice takes effect for this source.
  public var honorsSettings: Bool {
    switch self {
    case .environment, .developmentCheckout:
      false
    case .settings, .bundledDefault, .applicationSupport:
      true
    }
  }
}

public struct ResolvedDataDirectory: Sendable, Equatable {
  public let url: URL
  public let source: DataDirectorySource

  public init(url: URL, source: DataDirectorySource) {
    self.url = url
    self.source = source
  }
}

/// Resolves the data root (the directory that contains `runtime/`).
///
/// Order: `WALLEBRAIN_BASE_DIR` → development checkout → stored setting →
/// bundled default (when it exists) → `~/Library/Application Support/WalleBrain`.
/// Nothing is ever moved or copied between locations.
public struct DataDirectoryResolver: Sendable {
  public static let environmentKey = "WALLEBRAIN_BASE_DIR"
  public static let bundledDefaultInfoKey = "WalleBrainDefaultDataDirectory"

  public var environment: [String: String]
  public var storedPath: String?
  public var currentDirectory: URL
  public var bundleURL: URL
  public var bundledDefaultPath: String?
  public var applicationSupportDirectory: URL
  public var fileExists: @Sendable (String) -> Bool

  public init(
    environment: [String: String],
    storedPath: String?,
    currentDirectory: URL,
    bundleURL: URL,
    bundledDefaultPath: String?,
    applicationSupportDirectory: URL,
    fileExists: @escaping @Sendable (String) -> Bool
  ) {
    self.environment = environment
    self.storedPath = storedPath
    self.currentDirectory = currentDirectory
    self.bundleURL = bundleURL
    self.bundledDefaultPath = bundledDefaultPath
    self.applicationSupportDirectory = applicationSupportDirectory
    self.fileExists = fileExists
  }

  public static func live(defaults: UserDefaults = .standard) -> DataDirectoryResolver {
    let fileManager = FileManager.default
    let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
    return DataDirectoryResolver(
      environment: ProcessInfo.processInfo.environment,
      storedPath: DataDirectorySettingsStore(defaults: defaults).storedPath(),
      currentDirectory: URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
      bundleURL: Bundle.main.bundleURL,
      bundledDefaultPath: Bundle.main.object(forInfoDictionaryKey: bundledDefaultInfoKey) as? String,
      applicationSupportDirectory: applicationSupport.appending(path: "WalleBrain", directoryHint: .isDirectory),
      fileExists: { FileManager.default.fileExists(atPath: $0) }
    )
  }

  public func resolve() -> ResolvedDataDirectory {
    if let explicit = Self.directoryURL(fromPath: environment[Self.environmentKey]) {
      return ResolvedDataDirectory(url: explicit, source: .environment)
    }

    if let checkout = developmentCheckout() {
      return ResolvedDataDirectory(url: checkout, source: .developmentCheckout)
    }

    if let stored = Self.directoryURL(fromPath: storedPath) {
      return ResolvedDataDirectory(url: stored, source: .settings)
    }

    if
      let bundled = Self.directoryURL(fromPath: bundledDefaultPath),
      fileExists(bundled.appending(path: "runtime", directoryHint: .isDirectory).path(percentEncoded: false))
    {
      return ResolvedDataDirectory(url: bundled, source: .bundledDefault)
    }

    return ResolvedDataDirectory(url: applicationSupportDirectory.standardizedFileURL, source: .applicationSupport)
  }

  private func developmentCheckout() -> URL? {
    if isPackageRoot(currentDirectory) {
      return currentDirectory.standardizedFileURL
    }

    if bundleURL.pathExtension == "app" {
      let nativeDirectory = bundleURL.deletingLastPathComponent()
      let runtimeDirectory = nativeDirectory.deletingLastPathComponent()
      let projectRoot = runtimeDirectory.deletingLastPathComponent()
      if
        nativeDirectory.lastPathComponent == "native",
        runtimeDirectory.lastPathComponent == "runtime",
        isPackageRoot(projectRoot)
      {
        return projectRoot.standardizedFileURL
      }
    }

    return nil
  }

  private func isPackageRoot(_ directory: URL) -> Bool {
    fileExists(directory.appending(path: "Package.swift", directoryHint: .notDirectory).path(percentEncoded: false))
  }

  static func directoryURL(fromPath path: String?) -> URL? {
    guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    let expanded = (trimmed as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
  }
}

public struct DataDirectorySettingsStore {
  public static let key = "WalleBrain.DataDirectory"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func storedPath() -> String? {
    guard let path = defaults.string(forKey: Self.key)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
      return nil
    }
    return path
  }

  public func save(_ directory: URL) {
    defaults.set(directory.standardizedFileURL.path(percentEncoded: false), forKey: Self.key)
  }

  /// Resolves the data root for the app and, on first launch, records the default
  /// it picked so later launches keep using it even if the default would change.
  public func resolveAndRecordDefault(using resolver: DataDirectoryResolver) -> ResolvedDataDirectory {
    let resolved = resolver.resolve()
    if storedPath() == nil, [.bundledDefault, .applicationSupport].contains(resolved.source) {
      save(resolved.url)
    }
    return resolved
  }
}
