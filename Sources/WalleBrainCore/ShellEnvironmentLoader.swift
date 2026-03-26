import Foundation

enum ShellEnvironmentLoader {
  static func mergedEnvironment(
    from environment: [String: String],
    zshrcURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zshrc", directoryHint: .notDirectory)
  ) -> [String: String] {
    guard let contents = try? String(contentsOf: zshrcURL, encoding: .utf8) else {
      return environment
    }

    var merged = environment
    for line in contents.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
        continue
      }

      let normalized = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
      let parts = normalized.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else {
        continue
      }

      let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
      let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard merged[key].map({ !$0.isEmpty }) != true else {
        continue
      }

      merged[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    return merged
  }
}
