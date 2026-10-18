import Foundation

public struct CLIFileSystem: Sendable {
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

  public static let live = CLIFileSystem(
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

/// A local command-line tool that can run post-processing prompts.
public struct LocalCLITool: Sendable, Equatable {
  /// Label recorded as the session provider, e.g. "Codex CLI".
  public let displayName: String
  public let binaryName: String
  /// Searched after the configured path and `PATH`, in order. A GUI app's `PATH` usually lacks these.
  public let fallbackSearchDirectories: [String]
  public let installHint: String

  public static let codex = LocalCLITool(
    displayName: "Codex CLI",
    binaryName: "codex",
    fallbackSearchDirectories: ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"],
    installHint: "Install it with `npm install -g @openai/codex`."
  )

  public static let claudeCode = LocalCLITool(
    displayName: "Claude Code CLI",
    binaryName: "claude",
    fallbackSearchDirectories: ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"],
    installHint: "Install it with `curl -fsSL https://claude.ai/install.sh | bash`, then run `claude auth login`."
  )
}

/// Finds candidate binaries for a local CLI tool. Order: configured path, `PATH`, then the tool's fallback
/// directories.
///
/// The npm `@openai/codex` package installs `codex` as a Node wrapper (`bin/codex.js`) that spawns a platform
/// binary. The wrapper needs `node` on `PATH` and breaks when the platform package layout does not match, so for
/// that wrapper the native binaries it would launch are tried first.
public struct CLIExecutableResolver: Sendable {
  public var tool: LocalCLITool
  public var configuredPath: String?
  public var environmentPATH: String?
  public var homeDirectory: String
  public var fileSystem: CLIFileSystem

  public init(
    tool: LocalCLITool = .codex,
    configuredPath: String?,
    environmentPATH: String?,
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
    fileSystem: CLIFileSystem = .live
  ) {
    self.tool = tool
    self.configuredPath = configuredPath
    self.environmentPATH = environmentPATH
    self.homeDirectory = homeDirectory
    self.fileSystem = fileSystem
  }

  /// The tool's fallback directories with `~` expanded.
  public var fallbackSearchDirectories: [String] {
    tool.fallbackSearchDirectories.map(expandTilde)
  }

  /// Every location searched, in order, before checking the file system.
  public func searchLocations() -> [String] {
    var locations: [String] = []
    if let configured = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
      let expanded = expandTilde(configured)
      locations.append(fileSystem.isDirectory(expanded) ? join(expanded, tool.binaryName) : expanded)
    }

    let pathDirectories = (environmentPATH ?? "")
      .split(separator: ":", omittingEmptySubsequences: true)
      .map(String.init)
    for directory in pathDirectories + tool.fallbackSearchDirectories {
      locations.append(join(expandTilde(directory), tool.binaryName))
    }

    return deduplicated(locations)
  }

  /// Existing executables to try, in order. Each still needs a `--version` check before use.
  public func executableCandidates() -> [String] {
    var candidates: [String] = []
    for location in searchLocations() where fileSystem.isExecutableFile(location) {
      let realPath = fileSystem.resolvingSymlinks(location)
      if tool.binaryName == LocalCLITool.codex.binaryName, realPath.hasSuffix(".js") {
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
