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
    let environment = ProcessInfo.processInfo.environment
    if let explicit = environment["WALLEBRAIN_BASE_DIR"], !explicit.isEmpty {
      return URL(fileURLWithPath: explicit, isDirectory: true)
    }

    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    if FileManager.default.fileExists(atPath: current.appending(path: "Package.swift").path(percentEncoded: false)) {
      return current
    }

    let bundleURL = Bundle.main.bundleURL
    if bundleURL.pathExtension == "app" {
      let runtimeDirectory = bundleURL.deletingLastPathComponent()
      let projectRoot = runtimeDirectory.deletingLastPathComponent().deletingLastPathComponent()
      if FileManager.default.fileExists(atPath: projectRoot.appending(path: "Package.swift").path(percentEncoded: false)) {
        return projectRoot
      }
    }

    return current
  }
}
