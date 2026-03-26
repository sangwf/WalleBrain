import AppKit
import SwiftUI
import WalleBrainCore

struct ContentView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    HStack(spacing: 0) {
      SidebarView(model: model)
        .frame(width: 290)

      Divider()

      switch model.selectedItem {
      case .meeting, nil:
        MeetingWorkspaceView(model: model)
      case .dictionary:
        TermDictionaryView(model: model)
      case .acceptance:
        AcceptanceView(model: model)
      }
    }
    .frame(minWidth: 1240, minHeight: 780)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

struct SmokeRunnerView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("WalleBrain Smoke")
        .font(.title2.weight(.semibold))
      Text(model.runtimeStatusText)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(minWidth: 420, minHeight: 180, alignment: .topLeading)
  }
}

private struct SidebarView: View {
  @ObservedObject var model: AppModel
  private let showsDeveloperSection = ProcessInfo.processInfo.environment["WALLEBRAIN_SHOW_DEVELOPER_UI"] == "1"
  @State private var showsSettings = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      WorkspaceSection(model: model)
      Divider()
      MeetingsSection(model: model)
      Spacer()
      SettingsSection {
        model.loadModelConfiguration()
        showsSettings = true
      }
      if showsDeveloperSection {
        DeveloperSection(model: model)
      }
    }
    .padding(16)
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(isPresented: $showsSettings) {
      SettingsSheetView(model: model)
    }
  }
}

private struct WorkspaceSection: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Workspace")
        .font(.caption)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      ForEach(model.primarySidebarItems) { item in
        sidebarButton(
          title: item.rawValue,
          systemImage: item == .meeting ? "doc.text" : "book.closed"
        ) {
          model.selectSidebarItem(item)
        }
      }
    }
  }

  private func sidebarButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .frame(width: 16)
        Text(title)
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(isSelected(title: title) ? Color.accentColor.opacity(0.14) : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private func isSelected(title: String) -> Bool {
    model.selectedItem?.rawValue == title
  }
}

private struct MeetingsSection: View {
  @ObservedObject var model: AppModel
  @State private var pendingDeletion: NativeMeetingSession?
  @State private var showsDeleteConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Meetings")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
        Spacer()
        Button {
          model.startNewMeetingDraft()
        } label: {
          Image(systemName: "square.and.pencil")
            .font(.caption)
        }
        .buttonStyle(.plain)
        Spacer()
        Button {
          Task {
            await model.loadRecentSessions()
          }
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.caption)
        }
        .buttonStyle(.plain)
      }

      if model.recentSessions.isEmpty {
        Text("No meetings yet")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(model.recentSessions) { session in
              HStack(spacing: 8) {
                Button {
                  model.openSession(session)
                } label: {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                      .font(.subheadline.weight(.medium))
                      .lineLimit(1)
                    HStack(spacing: 6) {
                      Text(session.status.rawValue.capitalized)
                      Text("•")
                      Text(formatted(session.startedAt))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 10)
                  .background(model.currentSession?.id == session.id ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06))
                  .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                  pendingDeletion = session
                  showsDeleteConfirmation = true
                } label: {
                  Image(systemName: "trash")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.canDeleteSession(session) ? .secondary : .tertiary)
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!model.canDeleteSession(session))
                .help(model.canDeleteSession(session) ? "Delete meeting" : "Can't delete while running")
              }
            }
          }
        }
      }
    }
    .confirmationDialog(
      "Delete this meeting?",
      isPresented: $showsDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        guard let pendingDeletion else {
          return
        }

        Task {
          await model.deleteSession(pendingDeletion)
          await MainActor.run {
            self.pendingDeletion = nil
          }
        }
      }

      Button("Cancel", role: .cancel) {
        pendingDeletion = nil
      }
    } message: {
      Text("This will remove the meeting record and its exported files.")
    }
  }

  private func formatted(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter.string(from: date)
  }
}

private struct DeveloperSection: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Developer")
        .font(.caption)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      Button {
        model.selectSidebarItem(.acceptance)
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "wrench.and.screwdriver")
            .frame(width: 16)
          Text("Acceptance")
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(model.selectedItem == .acceptance ? Color.accentColor.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      .buttonStyle(.plain)
    }
  }
}

private struct SettingsSection: View {
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Settings")
        .font(.caption)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      Button(action: action) {
        HStack(spacing: 10) {
          Image(systemName: "gearshape")
            .frame(width: 16)
          Text("Settings")
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      .buttonStyle(.plain)
    }
  }
}

private struct MeetingWorkspaceView: View {
  @ObservedObject var model: AppModel
  @AppStorage("meetingInspectorVisible") private var isInspectorVisible = false
  @State private var isTranscriptAutoFollow = true
  @State private var transcriptScrollRequestID = 0
  @State private var copyTranscriptTask: Task<Void, Never>?
  @State private var copyStructuredNotesTask: Task<Void, Never>?
  @State private var didCopyTranscript = false
  @State private var didCopyStructuredNotes = false
  @FocusState private var isTitleFieldFocused: Bool

  var body: some View {
    HStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          documentHeader
          controlStrip
          transcriptSection
          generatedSection
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .background(Color(nsColor: .textBackgroundColor))

      if isInspectorVisible {
        Divider()

        SessionInspector(model: model)
          .frame(width: 320)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.18), value: isInspectorVisible)
    .onChange(of: model.currentSession?.id) { _, _ in
      isTranscriptAutoFollow = true
      transcriptScrollRequestID += 1
      didCopyTranscript = false
      didCopyStructuredNotes = false
    }
    .onChange(of: isTitleFieldFocused) { _, focused in
      guard !focused else {
        return
      }

      Task {
        await model.commitMeetingTitleChange()
      }
    }
  }

  private var documentHeader: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 16) {
        TextField("Meeting title", text: $model.meetingTitle)
          .textFieldStyle(.plain)
          .font(.system(size: 34, weight: .bold, design: .rounded))
          .focused($isTitleFieldFocused)
          .onSubmit {
            Task {
              await model.commitMeetingTitleChange()
            }
          }

        Spacer(minLength: 12)

        Button {
          withAnimation(.easeInOut(duration: 0.18)) {
            isInspectorVisible.toggle()
          }
        } label: {
          Image(systemName: isInspectorVisible ? "sidebar.right" : "sidebar.trailing")
            .font(.title3.weight(.semibold))
        }
        .buttonStyle(.plain)
        .help(isInspectorVisible ? "Hide properties" : "Show properties")
      }

      HStack(spacing: 10) {
        metadataPill(model.currentSession?.status.rawValue.capitalized ?? "Idle")
        metadataPill(model.currentSession?.selectedInput?.name ?? "Microphone")
      }

      if model.shouldShowScreenRecordingHint {
        HStack(spacing: 10) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text("当前输入依赖 Screen Recording，但系统还没授权。未授权时会自动回退到纯麦克风。")
            .font(.subheadline)
          Spacer()
          Button("Open Screen Recording Settings") {
            model.openScreenRecordingSettings()
          }
          .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
    }
  }

  private var controlStrip: some View {
    HStack(spacing: 12) {
      Picker("Input", selection: $model.selectedInputID) {
        ForEach(model.availableInputs) { input in
          Text(input.name).tag(Optional(input.id))
        }
      }
      .labelsHidden()
      .frame(maxWidth: 420)

      Button {
        model.refreshAudioInputs()
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.body.weight(.medium))
      }
      .buttonStyle(.plain)

      Spacer(minLength: 12)

      Button("Start Meeting") {
        Task {
          await model.startMeeting()
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!model.canStartMeeting)

      Button("Stop & Process") {
        Task {
          await model.stopMeetingAndProcess()
        }
      }
      .buttonStyle(.bordered)
      .disabled(!model.canStopMeeting)
    }
    .padding(18)
    .background(Color.secondary.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var transcriptSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Live Transcript")
          .font(.title3.weight(.semibold))
        Spacer()
        Button {
          copyTranscript()
        } label: {
          Label(didCopyTranscript ? "Copied" : "Copy Transcript", systemImage: didCopyTranscript ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(transcriptText.isEmpty)

        if let count = model.currentSession?.transcriptChunks.count, count > 0 {
          Text("\(count) chunks")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      ZStack(alignment: .bottomTrailing) {
        if transcriptText.isEmpty {
          Text("Live transcript will appear here after the meeting starts.")
            .font(.system(size: 22, weight: .regular, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(18)
        } else {
          TranscriptTextView(
            text: transcriptText,
            isAutoFollow: $isTranscriptAutoFollow,
            scrollRequestID: transcriptScrollRequestID
          )
        }

        if !transcriptText.isEmpty, !isTranscriptAutoFollow {
          Button("Back to Latest") {
            isTranscriptAutoFollow = true
            transcriptScrollRequestID += 1
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .padding(16)
        }
      }
        .frame(maxWidth: .infinity, minHeight: 360, maxHeight: 520, alignment: .topLeading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
  }

  private var generatedSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Structured Notes")
          .font(.title3.weight(.semibold))
        Spacer()
        Button {
          copyStructuredNotes()
        } label: {
          Label(didCopyStructuredNotes ? "Copied" : "Copy Notes", systemImage: didCopyStructuredNotes ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(structuredNotesText.isEmpty)
      }

      documentBlock(title: "Summary", content: model.currentSession?.summary ?? "Summary will be generated after you stop the meeting.")
      documentBlock(
        title: "Organized Transcript",
        content: organizedTranscriptText
      )
      documentBlock(title: "Key Points", content: bulletList(model.currentSession?.keyPoints))
      documentBlock(title: "Action Items", content: bulletList(model.currentSession?.actionItems))
    }
  }

  private func metadataPill(_ text: String) -> some View {
    Text(text)
      .font(.caption.weight(.medium))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Color.secondary.opacity(0.08))
      .clipShape(Capsule())
  }

  private func documentBlock(title: String, content: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      Text(content)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(Color.secondary.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func bulletList(_ items: [String]?) -> String {
    guard let items, !items.isEmpty else {
      return "None"
    }
    return items.map { "• \($0)" }.joined(separator: "\n")
  }

  private var transcriptText: String {
    model.currentSession?.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? model.currentSession?.liveTranscript ?? ""
      : ""
  }

  private var organizedTranscriptText: String {
    model.currentSession?.organizedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? model.currentSession?.organizedTranscript ?? ""
      : "Organized transcript will be generated after you stop the meeting."
  }

  private var summaryText: String {
    let trimmed = model.currentSession?.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed
  }

  private var structuredNotesText: String {
    var sections: [String] = []

    if !summaryText.isEmpty {
      sections.append("Summary\n\(summaryText)")
    }

    let organized = model.currentSession?.organizedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !organized.isEmpty {
      sections.append("Organized Transcript\n\(organized)")
    }

    if let keyPoints = model.currentSession?.keyPoints, !keyPoints.isEmpty {
      sections.append("Key Points\n" + keyPoints.map { "- \($0)" }.joined(separator: "\n"))
    }

    if let actionItems = model.currentSession?.actionItems, !actionItems.isEmpty {
      sections.append("Action Items\n" + actionItems.map { "- \($0)" }.joined(separator: "\n"))
    }

    return sections.joined(separator: "\n\n")
  }

  private func copyTranscript() {
    guard !transcriptText.isEmpty else {
      return
    }

    copyToPasteboard(transcriptText)
    didCopyTranscript = true
    copyTranscriptTask?.cancel()
    copyTranscriptTask = Task {
      try? await Task.sleep(for: .seconds(1.6))
      await MainActor.run {
        didCopyTranscript = false
      }
    }
  }

  private func copyStructuredNotes() {
    guard !structuredNotesText.isEmpty else {
      return
    }

    copyToPasteboard(structuredNotesText)
    didCopyStructuredNotes = true
    copyStructuredNotesTask?.cancel()
    copyStructuredNotesTask = Task {
      try? await Task.sleep(for: .seconds(1.6))
      await MainActor.run {
        didCopyStructuredNotes = false
      }
    }
  }

  private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

private struct SessionInspector: View {
  @ObservedObject var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        inspectorCard("Properties") {
          inspectorLine("State", model.currentSession?.status.rawValue ?? "idle")
          inspectorLine("Mode", model.currentSession?.mode.rawValue ?? model.selectedMode.rawValue)
          inspectorLine("Input", model.currentSession?.selectedInput?.name ?? "Not selected")
          inspectorLine("Started", format(model.currentSession?.startedAt))
          inspectorLine("Ended", format(model.currentSession?.endedAt))
        }

        inspectorCard("Artifacts") {
          inspectorLine("Audio", model.currentSession?.audioFilePath ?? "Pending")
          inspectorLine("Note", model.currentSession?.exportedNotePath ?? "Pending")
          inspectorLine("Dictionary", model.currentSession?.dictionaryPath ?? "Pending")
        }

        inspectorCard("Runtime") {
          Text(model.runtimeStatusText)
            .frame(maxWidth: .infinity, alignment: .leading)
          if !model.lastExportPath.isEmpty {
            Divider()
            Text(model.lastExportPath)
              .font(.caption)
              .textSelection(.enabled)
          }
        }
      }
      .padding(20)
    }
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private func inspectorCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)
      content()
    }
    .padding(16)
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func inspectorLine(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value.isEmpty ? "Pending" : value)
        .textSelection(.enabled)
    }
  }

  private func format(_ date: Date?) -> String {
    guard let date else {
      return "Pending"
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
  }
}

private struct TermDictionaryView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Term Dictionary")
        .font(.largeTitle)

      Text("像 Obsidian 里的词典笔记一样直接编辑。这里的术语会同时进入 Apple Speech 定制资产和会后 DeerAPI 提示词。")
        .foregroundStyle(.secondary)

      HStack {
        Button("Reload") {
          Task {
            await model.loadDictionary()
          }
        }
        .buttonStyle(.bordered)

        Button("Save") {
          Task {
            await model.saveDictionary()
          }
        }
        .buttonStyle(.borderedProminent)
      }

      TextEditor(text: $model.dictionaryMarkdown)
        .font(.system(.body, design: .monospaced))
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct AcceptanceView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Acceptance")
        .font(.largeTitle)

      Text("保留给回归和开发验收使用，不作为主产品导航的一部分。")
        .foregroundStyle(.secondary)

      HStack {
        Button("Run Fixture Harness") {
          Task {
            await model.runFixtureHarness()
          }
        }
        .buttonStyle(.borderedProminent)

        if !model.lastAssetsPath.isEmpty {
          Text(model.lastAssetsPath)
            .font(.caption)
            .textSelection(.enabled)
        }
      }

      GroupBox("Current Status") {
        VStack(alignment: .leading, spacing: 8) {
          Text(model.statusMessage)
          if !model.lastExportPath.isEmpty {
            Text(model.lastExportPath)
              .font(.caption)
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Spacer()
    }
    .padding(28)
  }
}

private struct SettingsSheetView: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var revealsAPIKey = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Settings")
            .font(.largeTitle.weight(.bold))
          Text("Model Configuration")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") {
          dismiss()
        }
        .buttonStyle(.borderedProminent)
      }

      Text("Use `$ENV_VAR` to resolve from the current environment. Literal values are used as-is.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      GroupBox {
        VStack(alignment: .leading, spacing: 14) {
          configurationField(
            title: "Base URL",
            text: $model.modelBaseURLReference,
            preview: model.modelConfigurationPreview.baseURL,
            masksResolvedValue: false
          )

          configurationField(
            title: "API Key",
            text: $model.modelAPIKeyReference,
            preview: model.modelConfigurationPreview.apiKey,
            masksResolvedValue: true
          )

          modelsField
        }
        .padding(8)
      } label: {
        Text("LLM")
          .font(.headline)
      }

      HStack(spacing: 12) {
        Button("Test Connection") {
          Task {
            await model.testModelConfiguration()
          }
        }
        .buttonStyle(.bordered)
        .disabled(model.isTestingModelConfiguration || !model.modelConfigurationPreview.isValid)

        Button("Save") {
          model.saveModelConfiguration()
        }
        .buttonStyle(.borderedProminent)

        if model.isTestingModelConfiguration {
          ProgressView()
            .controlSize(.small)
        }

        Spacer()

        Text(model.modelConfigurationStatusMessage)
          .font(.subheadline)
          .foregroundStyle(model.modelConfigurationPreview.isValid ? Color.secondary : Color.red)
      }

      Spacer()
    }
    .padding(24)
    .frame(minWidth: 680, minHeight: 520, alignment: .topLeading)
  }

  @ViewBuilder
  private func configurationField(
    title: String,
    text: Binding<String>,
    preview: ResolvedConfigurationValue,
    masksResolvedValue: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)

      if title == "API Key" {
        HStack(spacing: 8) {
          if revealsAPIKey {
            TextField(title, text: text)
              .textFieldStyle(.roundedBorder)
          } else {
            SecureField(title, text: text)
              .textFieldStyle(.roundedBorder)
          }

          Button {
            revealsAPIKey.toggle()
          } label: {
            Image(systemName: revealsAPIKey ? "eye.slash" : "eye")
          }
          .buttonStyle(.plain)
        }
      } else {
        TextField(title, text: text)
          .textFieldStyle(.roundedBorder)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(preview.sourceDescription)
          .font(.caption)
          .foregroundStyle(.secondary)

        Text(
          masksResolvedValue
            ? model.maskedResolvedValue(for: preview)
            : (preview.resolvedValue?.isEmpty == false ? preview.resolvedValue! : "Unavailable")
        )
        .font(.caption.monospaced())
        .foregroundStyle(preview.errorMessage == nil ? Color.secondary : Color.red)

        if let errorMessage = preview.errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
  }

  private var modelsField: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Models")
        .font(.headline)

      TextField("Models", text: $model.modelsReference)
        .textFieldStyle(.roundedBorder)

      Text("Separate multiple models with commas. They will be tried from left to right.")
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 4) {
        Text(model.modelConfigurationPreview.models.sourceDescription)
          .font(.caption)
          .foregroundStyle(.secondary)

        Text(
          model.modelConfigurationPreview.models.resolvedValue?.isEmpty == false
            ? model.modelConfigurationPreview.models.resolvedValue!
            : "Unavailable"
        )
        .font(.caption.monospaced())
        .foregroundStyle(model.modelConfigurationPreview.models.errorMessage == nil ? Color.secondary : Color.red)

        if let errorMessage = model.modelConfigurationPreview.models.errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
        } else {
          Text("Resolved order: \(model.modelConfigurationPreview.resolvedModels.joined(separator: " → "))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
