import Foundation

public struct CodexFileSystem: Sendable {
  public var isExecutableFile: @Sendable (String) -> Bool
  public var isDirectory: @Sendable (String) -> Bool
  public var resolvingSymlinks: @Sendable (String) -> String

  public init(
    isExecutableFile: @escaping @Sendable (String) -> Bool,
    isDirectory: @escaping @Sendable (String) -> Bool,
    resolvingSymlinks: @escaping @Sendable (String) -> String
  ) {
    self.isExecutableFile = isExecutableFile
    self.isDirectory = isDirectory
    self.resolvingSymlinks = resolvingSymlinks
  }

  public static let live = CodexFileSystem(
    isExecutableFile: { path in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
        && FileManager.default.isExecutableFile(atPath: path)
    },
    isDirectory: { path in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    },
    resolvingSymlinks: { path in
      URL(fileURLWithPath: path).resolvingSymlinksInPath().path(percentEncoded: false)
    }
  )
}

/// Finds candidate `codex` binaries. Order: configured path, `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`,
/// `~/.local/bin`. A GUI app's `PATH` usually lacks Homebrew, hence the fixed fallbacks.
///
/// The npm package installs `codex` as a Node wrapper (`bin/codex.js`) that spawns a platform binary. The
/// wrapper needs `node` on `PATH` and breaks when the platform package layout does not match, so for a
/// wrapper the native binaries it would launch are tried first.
public struct CodexExecutableResolver: Sendable {
  public static let fallbackSearchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"]

  public var configuredPath: String?
  public var environmentPATH: String?
  public var homeDirectory: String
  public var fileSystem: CodexFileSystem

  public init(
    configuredPath: String?,
    environmentPATH: String?,
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
    fileSystem: CodexFileSystem = .live
  ) {
    self.configuredPath = configuredPath
    self.environmentPATH = environmentPATH
    self.homeDirectory = homeDirectory
    self.fileSystem = fileSystem
  }

  /// Every location searched, in order, before checking the file system.
  public func searchLocations() -> [String] {
    var locations: [String] = []
    if let configured = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
      let expanded = expandTilde(configured)
      locations.append(fileSystem.isDirectory(expanded) ? join(expanded, "codex") : expanded)
    }

    let pathDirectories = (environmentPATH ?? "")
      .split(separator: ":", omittingEmptySubsequences: true)
      .map(String.init)
    for directory in pathDirectories + Self.fallbackSearchDirectories {
      locations.append(join(expandTilde(directory), "codex"))
    }

    return deduplicated(locations)
  }

  /// Existing executables to try, in order. Each still needs a `codex --version` check before use.
  public func executableCandidates() -> [String] {
    var candidates: [String] = []
    for location in searchLocations() where fileSystem.isExecutableFile(location) {
      let realPath = fileSystem.resolvingSymlinks(location)
      if realPath.hasSuffix(".js") {
        candidates += Self.nativeBinaryCandidates(forWrapperAt: realPath).filter(fileSystem.isExecutableFile)
      }
      candidates.append(location)
    }
    return deduplicated(candidates)
  }

  /// Native binaries an npm `@openai/codex` wrapper at `<package>/bin/codex.js` may launch.
  public static func nativeBinaryCandidates(forWrapperAt wrapperRealPath: String) -> [String] {
    let packageDirectory = URL(fileURLWithPath: wrapperRealPath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .path(percentEncoded: false)
    let trimmedPackageDirectory = packageDirectory.hasSuffix("/") ? String(packageDirectory.dropLast()) : packageDirectory
    let scopeDirectory = URL(fileURLWithPath: trimmedPackageDirectory).deletingLastPathComponent().path(percentEncoded: false)

    #if arch(arm64)
    let platformPackage = "codex-darwin-arm64"
    let targetTriple = "aarch64-apple-darwin"
    #else
    let platformPackage = "codex-darwin-x64"
    let targetTriple = "x86_64-apple-darwin"
    #endif

    let vendorRoots = [
      "\(trimmedPackageDirectory)/node_modules/@openai/\(platformPackage)/vendor/\(targetTriple)",
      "\(scopeDirectory.hasSuffix("/") ? String(scopeDirectory.dropLast()) : scopeDirectory)/\(platformPackage)/vendor/\(targetTriple)",
      "\(trimmedPackageDirectory)/vendor/\(targetTriple)",
    ]
    return vendorRoots.flatMap { ["\($0)/codex/codex", "\($0)/bin/codex"] }
  }

  private func expandTilde(_ path: String) -> String {
    if path == "~" {
      return homeDirectory
    }
    if path.hasPrefix("~/") {
      return join(homeDirectory, String(path.dropFirst(2)))
    }
    return path
  }

  private func join(_ directory: String, _ component: String) -> String {
    directory.hasSuffix("/") ? directory + component : directory + "/" + component
  }

  private func deduplicated(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
  }
}
