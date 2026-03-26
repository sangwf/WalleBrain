import AppKit
import Combine
import CoreGraphics
import Foundation
import WalleBrainCore

@MainActor
final class AppModel: ObservableObject {
  enum SidebarItem: String, CaseIterable, Identifiable {
    case meeting = "Meetings"
    case dictionary = "Dictionary"
    case acceptance = "Acceptance"

    var id: String { rawValue }
  }

  @Published var selectedItem: SidebarItem? = .meeting
  @Published var dictionaryMarkdown = ""
  @Published var statusMessage = "Idle"
  @Published var lastExportPath = ""
  @Published var lastAssetsPath = ""
  @Published var meetingTitle = "产品讨论会"
  @Published var selectedMode: MeetingMode = .normal
  @Published var availableInputs: [AudioInputDevice] = []
  @Published var selectedInputID: String?
  @Published var currentSession: NativeMeetingSession?
  @Published var recentSessions: [NativeMeetingSession] = []
  @Published var isMeetingActionInFlight = false
  @Published var modelBaseURLReference = "$DEERAPI_BASE_URL"
  @Published var modelAPIKeyReference = "$DEERAPI_KEY"
  @Published var modelsReference = "gemini-3-flash-preview"
  @Published var modelConfigurationStatusMessage = ""
  @Published var isTestingModelConfiguration = false

  private let paths = RuntimePaths()
  private var liveCoordinator: LiveMeetingCoordinator
  private var activeLiveSessionID: UUID?
  private var isRecentSessionsReloadInFlight = false
  private var recentSessionsReloadVersion = 0

  init() {
    liveCoordinator = LiveMeetingCoordinator(paths: paths) { _ in }
    liveCoordinator = LiveMeetingCoordinator(paths: paths) { [weak self] session in
      await MainActor.run {
        if [.preparing, .recording, .processing].contains(session.status) {
          self?.activeLiveSessionID = session.id
        } else if self?.activeLiveSessionID == session.id {
          self?.activeLiveSessionID = nil
        }
        self?.currentSession = session
        self?.lastExportPath = session.exportedNotePath ?? self?.lastExportPath ?? ""
        if session.status == .exported || session.status == .failed {
          self?.upsertRecentSession(session)
        }
      }
    }
  }

  func bootstrap() async {
    await loadDictionary()
    loadModelConfiguration()
    refreshAudioInputs()
    await loadRecentSessions()
    if currentSession == nil {
      prepareNewMeetingDraft()
    } else if currentSession?.status != .recording {
      selectedInputID = preferredUsableInput(from: availableInputs)?.id
    }
    await runLaunchSmokeIfRequested()
  }

  func refreshAudioInputs() {
    let inputs = AudioInputCatalog.availableInputs()
    availableInputs = inputs
    if let selectedInputID, inputs.contains(where: { $0.id == selectedInputID }) {
      return
    }
    selectedInputID = preferredUsableInput(from: inputs)?.id
  }

  func loadDictionary() async {
    do {
      let store = TermDictionaryStore(paths: paths)
      dictionaryMarkdown = try await store.loadRawMarkdown()
      if currentSession == nil {
        statusMessage = "Loaded term dictionary."
      }
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  func saveDictionary() async {
    do {
      let store = TermDictionaryStore(paths: paths)
      try await store.saveRawMarkdown(dictionaryMarkdown)
      statusMessage = "Saved term dictionary."
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  func loadModelConfiguration() {
    let configuration = ModelConfigurationStore().load()
    modelBaseURLReference = configuration.baseURLReference
    modelAPIKeyReference = configuration.apiKeyReference
    modelsReference = configuration.modelsReference
    if modelConfigurationStatusMessage.isEmpty {
      modelConfigurationStatusMessage = "Ready"
    }
  }

  func saveModelConfiguration() {
    ModelConfigurationStore().save(currentModelConfiguration)
    modelConfigurationStatusMessage = "Saved"
  }

  func testModelConfiguration() async {
    guard !isTestingModelConfiguration else {
      return
    }

    isTestingModelConfiguration = true
    defer { isTestingModelConfiguration = false }

    do {
      let result = try await DeerAPIClient(configuration: currentModelConfiguration).testConnection()
      modelConfigurationStatusMessage = "Connected via \(result.model)"
    } catch {
      modelConfigurationStatusMessage = error.localizedDescription
    }
  }

  func loadRecentSessions() async {
    recentSessionsReloadVersion += 1

    guard !isRecentSessionsReloadInFlight else {
      return
    }

    repeat {
      let versionBeingProcessed = recentSessionsReloadVersion
      isRecentSessionsReloadInFlight = true
      await loadRecentSessionsNow()
      isRecentSessionsReloadInFlight = false

      if versionBeingProcessed == recentSessionsReloadVersion {
        break
      }
    } while true
  }

  private func loadRecentSessionsNow() async {
    do {
      let store = MeetingSessionStore(paths: paths)
      let sessions = try await store.listSessions(limit: 12)
      recentSessions = sessions
      if currentSession == nil, let first = sessions.first,
        [.preparing, .recording, .processing].contains(first.status)
      {
        applySession(first)
      }
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  func selectSidebarItem(_ item: SidebarItem) {
    selectedItem = item
  }

  var primarySidebarItems: [SidebarItem] {
    [.meeting, .dictionary]
  }

  func openSession(_ session: NativeMeetingSession) {
    applySession(session)
    selectedItem = .meeting
  }

  func startNewMeetingDraft() {
    prepareNewMeetingDraft()
    selectedItem = .meeting
  }

  func commitMeetingTitleChange() async {
    let normalized = normalizedMeetingTitle(from: meetingTitle)
    if normalized != meetingTitle {
      meetingTitle = normalized
    }

    guard var session = currentSession else {
      return
    }

    guard session.title != normalized else {
      return
    }

    session.title = normalized
    currentSession = session
    upsertRecentSession(session)

    if let liveSession = await liveCoordinator.latestSession(), liveSession.id == session.id {
      do {
        try await liveCoordinator.updateMeetingTitle(normalized)
      } catch {
        statusMessage = error.localizedDescription
      }
      return
    }

    do {
      let store = MeetingSessionStore(paths: paths)
      try await store.save(session)
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  func canDeleteSession(_ session: NativeMeetingSession) -> Bool {
    activeLiveSessionID != session.id
  }

  func deleteSession(_ session: NativeMeetingSession) async {
    guard canDeleteSession(session) else {
      statusMessage = "You can't delete a meeting while it is still running."
      return
    }

    do {
      let store = MeetingSessionStore(paths: paths)
      try await store.delete(session)

      recentSessions.removeAll { $0.id == session.id }

      if currentSession?.id == session.id {
        if let nextSession = recentSessions.first {
          applySession(nextSession)
        } else {
          prepareNewMeetingDraft()
        }
      }

      if lastExportPath == session.exportedNotePath {
        lastExportPath = ""
      }

      statusMessage = "Deleted \(session.title)."
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  func toggleMeetingFromHotkey() async {
    NSApp.activate(ignoringOtherApps: true)
    selectedItem = .meeting

    if currentSession?.status == .recording {
      await stopMeetingAndProcess()
      return
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm:ss"
    meetingTitle = "会议记录 \(formatter.string(from: Date()))"
    selectedInputID = preferredUsableInput(from: availableInputs)?.id
    await startMeeting()
  }

  func startMeeting() async {
    guard !isMeetingActionInFlight else {
      return
    }

    isMeetingActionInFlight = true
    defer { isMeetingActionInFlight = false }

    do {
      try await liveCoordinator.startMeeting(
        title: meetingTitle,
        mode: selectedMode,
        preferredInputID: selectedInputID
      )
    } catch {
      handleMeetingStartError(error)
    }
  }

  func stopMeetingAndProcess() async {
    guard !isMeetingActionInFlight else {
      return
    }

    isMeetingActionInFlight = true
    defer { isMeetingActionInFlight = false }

    do {
      try await liveCoordinator.stopMeetingAndProcess()
      if let session = currentSession, session.status == .exported || session.status == .failed {
        upsertRecentSession(session)
      }
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  func runFixtureHarness() async {
    statusMessage = "Running native fixture harness..."

    do {
      let harness = FixtureHarness(paths: paths)
      let result = try await harness.run(transcript: "高德地图")
      lastExportPath = result.notePath.path(percentEncoded: false)
      lastAssetsPath = result.assets.languageModelURL.path(percentEncoded: false)
      statusMessage = "Harness succeeded via \(result.deerAPI.model)."
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  var canStartMeeting: Bool {
    guard !isMeetingActionInFlight else {
      return false
    }

    switch currentSession?.status {
    case .preparing, .recording, .processing:
      return false
    default:
      return true
    }
  }

  var canStopMeeting: Bool {
    guard !isMeetingActionInFlight else {
      return false
    }

    return currentSession?.status == .recording
  }

  private static func statusCopy(for session: NativeMeetingSession) -> String {
    switch session.status {
    case .idle:
      return "Idle"
    case .preparing:
      return "Preparing \(session.title)..."
    case .recording:
      return "Recording \(session.title) via \(session.selectedInput?.name ?? "unknown input")."
    case .processing:
      return "Processing \(session.title)..."
    case .exported:
      return "Exported \(session.title) via \(session.model ?? "local")."
    case .failed:
      return session.errorMessage ?? "Meeting failed."
    }
  }

  private func applySession(_ session: NativeMeetingSession) {
    currentSession = session
    meetingTitle = session.title
    selectedMode = session.mode
    if [.preparing, .recording, .processing].contains(session.status) {
      selectedInputID = session.selectedInput?.id ?? selectedInputID
    } else if availableInputs.contains(where: { $0.id == selectedInputID }) == false {
      selectedInputID = preferredUsableInput(from: availableInputs)?.id
    }
    lastExportPath = session.exportedNotePath ?? lastExportPath
  }

  private func prepareNewMeetingDraft() {
    currentSession = nil
    meetingTitle = "产品讨论会"
    selectedMode = .normal
    selectedInputID = preferredUsableInput(from: availableInputs)?.id
  }

  private func normalizedMeetingTitle(from rawTitle: String) -> String {
    let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "会议记录" : trimmed
  }

  private var currentModelConfiguration: ModelConfiguration {
    ModelConfiguration(
      baseURLReference: modelBaseURLReference,
      apiKeyReference: modelAPIKeyReference,
      modelsReference: modelsReference
    )
  }

  private func upsertRecentSession(_ session: NativeMeetingSession) {
    if let index = recentSessions.firstIndex(where: { $0.id == session.id }) {
      recentSessions[index] = session
    } else {
      recentSessions.append(session)
    }

    recentSessions.sort { left, right in
      if left.startedAt == right.startedAt {
        return left.id.uuidString > right.id.uuidString
      }
      return left.startedAt > right.startedAt
    }

    if recentSessions.count > 12 {
      recentSessions = Array(recentSessions.prefix(12))
    }
  }

  private func runLaunchSmokeIfRequested() async {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--smoke-meeting") else {
      return
    }

    let seconds = arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) ?? 3 : 3
    let smokeInput = argumentValue(named: "--smoke-input")
    let smokeTitle = argumentValue(named: "--smoke-title")
    let smokeFixtureSpeech = argumentValue(named: "--smoke-fixture-speech") ?? "你好，这是 WalleBrain 的系统音频录写测试。"

    if let smokeTitle, !smokeTitle.isEmpty {
      meetingTitle = smokeTitle
    }
    if let smokeInput {
      applySmokeInput(smokeInput)
    }

    try? await Task.sleep(for: .seconds(2))
    await startMeeting()
    guard currentSession?.status == .recording else {
      emitSmokePayload()
      NSApplication.shared.terminate(nil)
      return
    }

    do {
      if let selectedInputID, AudioInputCatalog.isSystemAudioInput(id: selectedInputID) {
        try playSystemAudioFixture(text: smokeFixtureSpeech)
        try await Task.sleep(for: .seconds(1))
      } else {
        try await Task.sleep(for: .seconds(seconds))
      }

      await stopMeetingAndProcess()
      emitSmokePayload()
    } catch {
      fputs("SMOKE_ERROR \(error.localizedDescription)\n", stderr)
    }

    NSApplication.shared.terminate(nil)
  }

  private func applySmokeInput(_ smokeInput: String) {
    switch smokeInput {
    case "mixed":
      selectedInputID = AudioInputCatalog.preferredInput(from: availableInputs)?.id
    case "system-audio":
      selectedInputID = AudioInputCatalog.systemAudioInputID
    case "microphone":
      selectedInputID = preferredMicrophoneInput(from: availableInputs)?.id
    default:
      break
    }
  }

  private func emitSmokePayload() {
    let payload: [String: Any] = [
      "status": currentSession?.status.rawValue ?? "unknown",
      "selectedInput": currentSession?.selectedInput?.name ?? "",
      "audioFile": currentSession?.audioFilePath ?? "",
      "noteFile": currentSession?.exportedNotePath ?? "",
      "transcriptLength": currentSession?.liveTranscript.count ?? 0,
      "model": currentSession?.model ?? "",
      "error": currentSession?.errorMessage ?? "",
    ]

    if
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    {
      print(text)
    }
  }

  private func argumentValue(named name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
      return nil
    }

    return arguments[index + 1]
  }

  private func playSystemAudioFixture(text: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = [text]
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw WalleBrainError.invalidResponse("System audio fixture playback failed.")
    }
  }

  var runtimeStatusText: String {
    if let currentSession {
      return Self.statusCopy(for: currentSession)
    }
    return statusMessage
  }

  var modelConfigurationPreview: ResolvedModelConfigurationPreview {
    ModelConfigurationResolver().preview(for: currentModelConfiguration)
  }

  func maskedResolvedValue(for value: ResolvedConfigurationValue) -> String {
    guard let resolvedValue = value.resolvedValue, !resolvedValue.isEmpty else {
      return "Unavailable"
    }

    if value.rawValue == modelAPIKeyReference {
      if resolvedValue.count <= 8 {
        return String(repeating: "•", count: max(resolvedValue.count, 4))
      }

      let prefix = resolvedValue.prefix(4)
      let suffix = resolvedValue.suffix(4)
      return "\(prefix)••••\(suffix)"
    }

    if resolvedValue.count > 72 {
      return String(resolvedValue.prefix(72)) + "…"
    }

    return resolvedValue
  }

  var screenRecordingAccessGranted: Bool {
    CGPreflightScreenCaptureAccess()
  }

  var selectedInputNeedsScreenRecording: Bool {
    guard let selectedInputID else {
      return false
    }

    return AudioInputCatalog.isSystemAudioInput(id: selectedInputID) || AudioInputCatalog.isMixedInput(id: selectedInputID)
  }

  var shouldShowScreenRecordingHint: Bool {
    selectedInputNeedsScreenRecording && !screenRecordingAccessGranted
  }

  func openScreenRecordingSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
      return
    }

    NSWorkspace.shared.open(url)
  }

  private func handleMeetingStartError(_ error: Error) {
    let description = error.localizedDescription
    if description.contains("Screen Recording access was denied.")
      || description.contains("Screen Recording access is required for System Audio.")
    {
      let fallback = preferredMicrophoneInput(from: availableInputs)
      selectedInputID = fallback?.id
      if let fallback {
        statusMessage = "System Audio 需要 Screen Recording。已切换到 \(fallback.name)。如果你刚刚在系统设置里授权过，请彻底退出并重新打开 WalleBrain 一次。"
      } else {
        statusMessage = "System Audio 需要 Screen Recording。如果你刚刚在系统设置里授权过，请彻底退出并重新打开 WalleBrain 一次；否则请改用纯麦克风输入。"
      }
      return
    }

    statusMessage = description
  }

  private func preferredUsableInput(from inputs: [AudioInputDevice]) -> AudioInputDevice? {
    if screenRecordingAccessGranted {
      return AudioInputCatalog.preferredInput(from: inputs)
    }

    return preferredMicrophoneInput(from: inputs)
  }

  private func preferredMicrophoneInput(from inputs: [AudioInputDevice]) -> AudioInputDevice? {
    inputs.first(where: {
      !AudioInputCatalog.isSystemAudioInput(id: $0.id)
        && !AudioInputCatalog.isMixedInput(id: $0.id)
        && ($0.name.contains("MacBook Pro麦克风")
          || ($0.name.lowercased().contains("macbook pro") && $0.name.lowercased().contains("microphone"))
          || $0.name.contains("内建麦克风")
          || $0.name.contains("MacBook Air麦克风")
          || $0.name.lowercased().contains("built-in microphone"))
    }) ?? inputs.first(where: {
      !AudioInputCatalog.isSystemAudioInput(id: $0.id) && !AudioInputCatalog.isMixedInput(id: $0.id)
    })
  }
}
