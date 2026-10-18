import Foundation

/// A backend that can run after-meeting processing. Tiers are tried in the configured order, per stage.
public enum PostProcessingTier: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
  case codex
  case claudeCode
  case api

  public static let defaultOrder: [PostProcessingTier] = [.codex, .claudeCode, .api]

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .codex:
      return "Codex CLI"
    case .claudeCode:
      return "Claude Code CLI"
    case .api:
      return "LLM API"
    }
  }

  /// Accepts the raw value plus short command-line spellings (`claude`).
  public init?(argument: String) {
    switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "codex":
      self = .codex
    case "claude", "claudecode", "claude-code":
      self = .claudeCode
    case "api":
      self = .api
    default:
      return nil
    }
  }
}

public struct PostProcessingTierSetting: Codable, Sendable, Hashable, Identifiable {
  public var tier: PostProcessingTier
  public var isEnabled: Bool

  public var id: PostProcessingTier { tier }

  public init(tier: PostProcessingTier, isEnabled: Bool) {
    self.tier = tier
    self.isEnabled = isEnabled
  }
}

public struct PostProcessingConfiguration: Codable, Sendable, Hashable {
  /// Every tier exactly once, in fallback order.
  public var tiers: [PostProcessingTierSetting]
  /// Optional explicit path to the `codex` binary. Empty means search the usual install locations.
  public var codexExecutablePath: String
  /// Optional `codex exec --model` override. Empty means the Codex CLI's own default model.
  public var codexModel: String
  /// Optional explicit path to the `claude` binary. Empty means search the usual install locations.
  public var claudeExecutablePath: String
  /// Optional `claude --model` override. Empty means the Claude Code CLI's own default model.
  public var claudeModel: String

  public init(
    tiers: [PostProcessingTierSetting] = PostProcessingConfiguration.defaultTiers,
    codexExecutablePath: String = "",
    codexModel: String = "",
    claudeExecutablePath: String = "",
    claudeModel: String = ""
  ) {
    self.tiers = Self.normalized(tiers)
    self.codexExecutablePath = codexExecutablePath
    self.codexModel = codexModel
    self.claudeExecutablePath = claudeExecutablePath
    self.claudeModel = claudeModel
  }

  public static let defaultTiers = PostProcessingTier.defaultOrder.map {
    PostProcessingTierSetting(tier: $0, isEnabled: true)
  }

  public var enabledTiers: [PostProcessingTier] {
    tiers.filter(\.isEnabled).map(\.tier)
  }

  /// Keeps the first occurrence of each tier and appends missing tiers (disabled) in default order.
  public static func normalized(_ tiers: [PostProcessingTierSetting]) -> [PostProcessingTierSetting] {
    var seen: Set<PostProcessingTier> = []
    var result = tiers.filter { seen.insert($0.tier).inserted }
    for tier in PostProcessingTier.defaultOrder where !seen.contains(tier) {
      result.append(PostProcessingTierSetting(tier: tier, isEnabled: false))
    }
    return result
  }

  // MARK: - Persistence

  enum Keys {
    static let tiers = "WalleBrain.ModelConfiguration.postProcessingTiers"
    /// Pre-chain setting: "codex" (Codex with API fallback) or "api" (API only). Still written for downgrades.
    static let legacyBackend = "WalleBrain.ModelConfiguration.postProcessingBackend"
    static let codexExecutablePath = "WalleBrain.ModelConfiguration.codexExecutablePath"
    static let codexModel = "WalleBrain.ModelConfiguration.codexModel"
    static let claudeExecutablePath = "WalleBrain.ModelConfiguration.claudeExecutablePath"
    static let claudeModel = "WalleBrain.ModelConfiguration.claudeModel"
  }

  static func load(from defaults: UserDefaults) -> PostProcessingConfiguration {
    let tiers: [PostProcessingTierSetting]
    if let stored = defaults.string(forKey: Keys.tiers), let decoded = decodeTiers(stored), !decoded.isEmpty {
      tiers = decoded
    } else if defaults.string(forKey: Keys.legacyBackend) == "api" {
      tiers = [
        PostProcessingTierSetting(tier: .api, isEnabled: true),
        PostProcessingTierSetting(tier: .codex, isEnabled: false),
        PostProcessingTierSetting(tier: .claudeCode, isEnabled: false),
      ]
    } else {
      tiers = defaultTiers
    }

    return PostProcessingConfiguration(
      tiers: tiers,
      codexExecutablePath: defaults.string(forKey: Keys.codexExecutablePath) ?? "",
      codexModel: defaults.string(forKey: Keys.codexModel) ?? "",
      claudeExecutablePath: defaults.string(forKey: Keys.claudeExecutablePath) ?? "",
      claudeModel: defaults.string(forKey: Keys.claudeModel) ?? ""
    )
  }

  func save(to defaults: UserDefaults) {
    defaults.set(Self.encodeTiers(tiers), forKey: Keys.tiers)
    defaults.set(enabledTiers == [.api] ? "api" : "codex", forKey: Keys.legacyBackend)
    defaults.set(codexExecutablePath, forKey: Keys.codexExecutablePath)
    defaults.set(codexModel, forKey: Keys.codexModel)
    defaults.set(claudeExecutablePath, forKey: Keys.claudeExecutablePath)
    defaults.set(claudeModel, forKey: Keys.claudeModel)
  }

  /// `codex:1,claudeCode:1,api:0`
  static func encodeTiers(_ tiers: [PostProcessingTierSetting]) -> String {
    tiers.map { "\($0.tier.rawValue):\($0.isEnabled ? 1 : 0)" }.joined(separator: ",")
  }

  static func decodeTiers(_ value: String) -> [PostProcessingTierSetting]? {
    let settings = value.split(separator: ",").compactMap { entry -> PostProcessingTierSetting? in
      let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
      guard let tier = parts.first.flatMap(PostProcessingTier.init(rawValue:)) else {
        return nil
      }
      return PostProcessingTierSetting(tier: tier, isEnabled: parts.count < 2 || parts[1] != "0")
    }
    return settings.isEmpty ? nil : settings
  }
}
