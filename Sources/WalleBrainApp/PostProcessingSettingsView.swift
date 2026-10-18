import SwiftUI
import WalleBrainCore

extension AppModel {
  /// Resolves and version-checks a local CLI tier's binary without sending a prompt.
  func checkLocalCLI(_ tier: PostProcessingTier) async {
    guard tier != .api, !checkingLocalCLITiers.contains(tier) else {
      return
    }

    checkingLocalCLITiers.insert(tier)
    defer { checkingLocalCLITiers.remove(tier) }

    let configuration = postProcessingConfiguration
    do {
      let executable: LocalCLIExecutable
      switch tier {
      case .codex:
        executable = try await CodexCLIPostProcessingClient(
          options: LocalCLIOptions(executablePath: configuration.codexExecutablePath, model: configuration.codexModel)
        ).resolveExecutable()
      case .claudeCode:
        executable = try await ClaudeCodeCLIPostProcessingClient(
          options: LocalCLIOptions(executablePath: configuration.claudeExecutablePath, model: configuration.claudeModel)
        ).resolveExecutable()
      case .api:
        return
      }
      localCLIStatusMessages[tier] = "\(executable.version) at \(executable.path)"
    } catch {
      localCLIStatusMessages[tier] = error.localizedDescription
    }
  }
}

/// Settings → After-Meeting Processing: the ordered fallback chain of tiers and the local CLI options.
struct PostProcessingSettingsView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        Text("Each stage runs on the first enabled tier that succeeds, top to bottom. A tier that is missing, logged out or failing hands over to the next one.")
          .font(.caption)
          .foregroundStyle(.secondary)

        VStack(spacing: 6) {
          ForEach(Array(model.postProcessingConfiguration.tiers.enumerated()), id: \.element.id) { index, setting in
            tierRow(index: index, setting: setting)
          }
        }

        if isEnabled(.codex) {
          cliOptions(
            tier: .codex,
            title: "Codex CLI",
            path: $model.postProcessingConfiguration.codexExecutablePath,
            pathPlaceholder: "Auto-detect (PATH, /opt/homebrew/bin, /usr/local/bin, ~/.local/bin)",
            modelValue: $model.postProcessingConfiguration.codexModel,
            modelPlaceholder: "Codex default (from ~/.codex/config.toml)",
            checkTitle: "Check Codex"
          )
        }

        if isEnabled(.claudeCode) {
          cliOptions(
            tier: .claudeCode,
            title: "Claude Code CLI",
            path: $model.postProcessingConfiguration.claudeExecutablePath,
            pathPlaceholder: "Auto-detect (PATH, ~/.local/bin, /opt/homebrew/bin, /usr/local/bin)",
            modelValue: $model.postProcessingConfiguration.claudeModel,
            modelPlaceholder: "Claude Code default (e.g. opus, sonnet)",
            checkTitle: "Check Claude Code"
          )
        }
      }
      .padding(8)
    } label: {
      Text("After-Meeting Processing")
        .font(.headline)
    }
  }

  private func tierRow(index: Int, setting: PostProcessingTierSetting) -> some View {
    let tiers = model.postProcessingConfiguration.tiers
    let isLastEnabled = setting.isEnabled && tiers.filter(\.isEnabled).count == 1

    return HStack(spacing: 10) {
      Text("\(index + 1).")
        .font(.body.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 22, alignment: .trailing)

      Toggle(
        setting.tier.displayName,
        isOn: Binding(
          get: { model.postProcessingConfiguration.tiers[index].isEnabled },
          set: { model.postProcessingConfiguration.tiers[index].isEnabled = $0 }
        )
      )
      .disabled(isLastEnabled)
      .help(isLastEnabled ? "At least one tier must stay enabled." : "")

      Spacer()

      Button {
        moveTier(from: index, to: index - 1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .disabled(index == 0)

      Button {
        moveTier(from: index, to: index + 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .disabled(index == tiers.count - 1)
    }
  }

  private func cliOptions(
    tier: PostProcessingTier,
    title: String,
    path: Binding<String>,
    pathPlaceholder: String,
    modelValue: Binding<String>,
    modelPlaceholder: String,
    checkTitle: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)

      TextField(pathPlaceholder, text: path)
        .textFieldStyle(.roundedBorder)

      TextField(modelPlaceholder, text: modelValue)
        .textFieldStyle(.roundedBorder)

      HStack(spacing: 12) {
        Button(checkTitle) {
          Task {
            await model.checkLocalCLI(tier)
          }
        }
        .buttonStyle(.bordered)
        .disabled(model.checkingLocalCLITiers.contains(tier))

        if model.checkingLocalCLITiers.contains(tier) {
          ProgressView()
            .controlSize(.small)
        }

        Text(model.localCLIStatusMessages[tier] ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  private func isEnabled(_ tier: PostProcessingTier) -> Bool {
    model.postProcessingConfiguration.tiers.contains { $0.tier == tier && $0.isEnabled }
  }

  private func moveTier(from source: Int, to destination: Int) {
    var tiers = model.postProcessingConfiguration.tiers
    guard tiers.indices.contains(source), tiers.indices.contains(destination) else {
      return
    }
    tiers.swapAt(source, destination)
    model.postProcessingConfiguration.tiers = tiers
  }
}
