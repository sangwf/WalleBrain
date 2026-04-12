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
  @Published var manualTranscriptDraft = ""
  @Published var recentSessions: [NativeMeetingSession] = []
  @Published var isMeetingActionInFlight = false
  @Published var draftCorrections: [TranscriptCorrection] = []
  @Published var saveDraftCorrectionsToMemory = false
  @Published var modelBaseURLReference = "$DEERAPI_BASE_URL"
  @Published var modelAPIKeyReference = "$DEERAPI_KEY"
  @Published var modelsReference = ModelConfiguration.defaultModelsReference
  @Published var modelConfigurationStatusMessage = ""
  @Published var isTestingModelConfiguration = false

  private let paths = RuntimePaths()
  private var liveCoordinator: LiveMeetingCoordinator
  private var activeLiveSessionID: UUID?
  private var isRecentSessionsReloadInFlight = false
  private var recentSessionsReloadVersion = 0
  private var manualTranscriptSaveTask: Task<Void, Never>?

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

  func updateManualTranscriptDraft(_ transcript: String) {
    manualTranscriptDraft = transcript

    guard isManualTranscriptEditable, var session = currentSession else {
      return
    }

    session.liveTranscript = transcript
    session.transcriptChunks = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? []
      : [TranscriptChunk(id: "manual-input", startSeconds: 0, durationSeconds: 0, text: transcript)]
    currentSession = session

    manualTranscriptSaveTask?.cancel()
    manualTranscriptSaveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else {
        return
      }
      await self?.persistManualTranscriptDraft(transcript)
    }
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
      let sessions = try await store.listSessions()
      let visibleSessions = sessions.filter { !isHiddenTestSession($0) }
      let limitedSessions = Array(visibleSessions.prefix(12))
      recentSessions = limitedSessions
      if currentSession == nil, let first = limitedSessions.first,
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
      await commitMeetingTitleChange()
      if isManualTranscriptEditable {
        manualTranscriptSaveTask?.cancel()
        try await liveCoordinator.updateManualTranscript(manualTranscriptDraft)
      }
      try await liveCoordinator.stopMeetingAndProcess()
      if let session = currentSession, session.status == .exported || session.status == .failed {
        upsertRecentSession(session)
        if session.status == .failed, session.exportedNotePath != nil {
          statusMessage = "AI post-process failed; exported a transcript-only note."
        }
      }
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  func addDraftCorrection(wrong: String, correct: String, type: String? = nil) {
    guard canApplyCorrections else {
      return
    }

    guard let normalized = normalizedCorrection(
      TranscriptCorrection(wrong: wrong, correct: correct, type: type)
    ) else {
      statusMessage = "Please enter a different replacement for the selected text."
      return
    }

    if let existingIndex = draftCorrections.firstIndex(where: { $0.wrong == normalized.wrong }) {
      draftCorrections[existingIndex] = normalized
      statusMessage = "Updated correction for \(normalized.wrong)."
      return
    }

    draftCorrections.append(normalized)
    statusMessage = "Queued correction for \(normalized.wrong)."
  }

  func removeDraftCorrection(_ correction: TranscriptCorrection) {
    draftCorrections.removeAll { $0.id == correction.id }
  }

  func regenerateNotesFromDraftCorrections() async {
    guard !isMeetingActionInFlight else {
      return
    }
    guard var session = currentSession else {
      return
    }

    let normalizedCorrections = draftCorrections.compactMap(normalizedCorrection)

    isMeetingActionInFlight = true
    defer { isMeetingActionInFlight = false }

    do {
      session.sessionCorrections = normalizedCorrections.isEmpty ? nil : normalizedCorrections
      session.status = .processing
      currentSession = session
      upsertRecentSession(session)
      try await MeetingSessionStore(paths: paths).save(session)

      if saveDraftCorrectionsToMemory {
        try await CorrectionMemoryStore(paths: paths).merge(normalizedCorrections)
      }

      session = try await MeetingPostProcessor(paths: paths).process(session)
      currentSession = session
      upsertRecentSession(session)
      lastExportPath = session.exportedNotePath ?? lastExportPath
      try await MeetingSessionStore(paths: paths).save(session)
      draftCorrections = session.sessionCorrections ?? []

      if session.status == .exported {
        statusMessage = "Regenerated notes via \(session.model ?? "local")."
      } else {
        statusMessage = "AI post-process failed; exported a transcript-only note."
      }
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  func reviewBlock(
    kind: MeetingBlockKind,
    type: ReviewFeedbackType,
    comment: String,
    proposedText: String?
  ) async {
    guard !isMeetingActionInFlight else {
      return
    }
    guard var session = currentSession else {
      return
    }

    let normalizedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedProposedText = proposedText?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard canReviewBlock(kind), !normalizedComment.isEmpty else {
      statusMessage = "Please enter a review comment for this block."
      return
    }

    let anchor = MeetingBlockAnchor(
      kind: kind,
      transcriptQuote: currentBlockQuote(for: kind, session: session)
    )
    let reviewComment = ReviewComment(
      anchor: anchor,
      type: type,
      comment: normalizedComment,
      proposedText: normalizedProposedText?.isEmpty == false ? normalizedProposedText : nil
    )
    let revisionRequest = RevisionRequest(
      scope: .block,
      anchor: anchor,
      instructions: revisionInstructions(
        kind: kind,
        type: type,
        comment: normalizedComment,
        proposedText: normalizedProposedText
      ),
      reviewCommentIDs: [reviewComment.id]
    )

    session.reviewComments = (session.reviewComments ?? []) + [reviewComment]
    session.revisionRequests = (session.revisionRequests ?? []) + [revisionRequest]
    currentSession = session
    upsertRecentSession(session)

    isMeetingActionInFlight = true
    defer { isMeetingActionInFlight = false }

    do {
      try await MeetingSessionStore(paths: paths).save(session)

      let client = try DeerAPIClient(configuration: currentModelConfiguration)
      var appliedComment = reviewComment
      appliedComment.status = .applied
      var appliedRequest = revisionRequest
      appliedRequest.status = .applied

      switch kind {
      case .executiveSummary:
        let revision = try await client.reviseSummary(
          transcript: transcriptForRevision(from: session),
          currentSummary: session.summary ?? "",
          reviewComment: reviewComment,
          request: revisionRequest
        )
        session.summary = revision.summary
        session.provider = revision.provider
        session.model = revision.model
      case .keyPoint:
        let items = try await client.reviseListBlock(
          transcript: transcriptForRevision(from: session),
          blockKind: kind,
          currentItems: session.keyPoints,
          reviewComment: reviewComment,
          request: revisionRequest
        )
        session.keyPoints = items
      case .actionItem:
        let items = try await client.reviseListBlock(
          transcript: transcriptForRevision(from: session),
          blockKind: kind,
          currentItems: session.actionItems,
          reviewComment: reviewComment,
          request: revisionRequest
        )
        session.actionItems = items
      case .decision:
        let decisions = try await client.reviseDecisionsBlock(
          transcript: transcriptForRevision(from: session),
          currentDecisions: session.decisions ?? [],
          reviewComment: reviewComment,
          request: revisionRequest
        )
        session.decisions = decisions
      default:
        throw WalleBrainError.invalidResponse("Unsupported review block: \(kind.rawValue)")
      }

      session.reviewComments = replaceReviewComment(appliedComment, in: session.reviewComments ?? [])
      session.revisionRequests = replaceRevisionRequest(appliedRequest, in: session.revisionRequests ?? [])

      session = try await exportAndSaveSession(session)
      currentSession = session
      upsertRecentSession(session)
      lastExportPath = session.exportedNotePath ?? lastExportPath
      statusMessage = "Rewrote \(reviewLabel(for: kind).lowercased()) via \(session.model ?? "local")."
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
    manualTranscriptDraft = session.liveTranscript
    draftCorrections = session.sessionCorrections ?? []
    saveDraftCorrectionsToMemory = false

    if let inputID = session.selectedInput?.id, availableInputs.contains(where: { $0.id == inputID }) {
      selectedInputID = inputID
    } else if availableInputs.contains(where: { $0.id == selectedInputID }) == false {
      selectedInputID = preferredUsableInput(from: availableInputs)?.id
    }
    lastExportPath = session.exportedNotePath ?? lastExportPath
  }

  private func prepareNewMeetingDraft() {
    manualTranscriptSaveTask?.cancel()
    currentSession = nil
    meetingTitle = "产品讨论会"
    selectedMode = .normal
    manualTranscriptDraft = ""
    draftCorrections = []
    saveDraftCorrectionsToMemory = false
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
    guard !isHiddenTestSession(session) else {
      return
    }

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

  private func isHiddenTestSession(_ session: NativeMeetingSession) -> Bool {
    let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      return false
    }

    let hiddenPrefixes = [
      "Native Real Smoke",
      "Native System Audio Smoke",
      "WalleBrain Native Harness",
      "Acceptance ",
      "Harness ",
      "Bridge Run ",
      "Silence Check",
    ]

    return hiddenPrefixes.contains { title.hasPrefix($0) }
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
      !AudioInputCatalog.isSystemAudioInput(id: $0.id)
        && !AudioInputCatalog.isMixedInput(id: $0.id)
        && !AudioInputCatalog.isManualInput(id: $0.id)
    })
  }

  private func persistManualTranscriptDraft(_ transcript: String) async {
    guard isManualTranscriptEditable else {
      return
    }

    do {
      try await liveCoordinator.updateManualTranscript(transcript)
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  var selectedInputIsManual: Bool {
    guard let selectedInputID else {
      return false
    }

    return AudioInputCatalog.isManualInput(id: selectedInputID)
  }

  var currentSessionUsesManualInput: Bool {
    AudioInputCatalog.isManualInput(id: currentSession?.selectedInput?.id ?? "")
  }

  var isManualTranscriptEditable: Bool {
    currentSessionUsesManualInput && currentSession?.status == .recording
  }

  var canApplyCorrections: Bool {
    guard !isMeetingActionInFlight, let currentSession else {
      return false
    }

    return [.exported, .failed].contains(currentSession.status)
      && !currentSession.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var currentSessionCorrections: [TranscriptCorrection] {
    draftCorrections
  }

  func canReviewBlock(_ kind: MeetingBlockKind) -> Bool {
    guard !isMeetingActionInFlight, let currentSession else {
      return false
    }

    let blockHasContent: Bool
    switch kind {
    case .executiveSummary:
      let summary = currentSession.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      blockHasContent = !summary.isEmpty
    case .keyPoint:
      blockHasContent = !currentSession.keyPoints.isEmpty
    case .actionItem:
      blockHasContent = !currentSession.actionItems.isEmpty
    case .decision:
      blockHasContent = !((currentSession.decisions ?? []).isEmpty)
    default:
      blockHasContent = false
    }

    return [.exported, .failed].contains(currentSession.status)
      && blockHasContent
      && !transcriptForRevision(from: currentSession).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func reviewCommentCount(for kind: MeetingBlockKind) -> Int {
    (currentSession?.reviewComments ?? []).filter { $0.anchor.kind == kind }.count
  }

  private func normalizedCorrection(_ correction: TranscriptCorrection) -> TranscriptCorrection? {
    let wrong = correction.wrong.trimmingCharacters(in: .whitespacesAndNewlines)
    let correct = correction.correct.trimmingCharacters(in: .whitespacesAndNewlines)
    let type = correction.type?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !wrong.isEmpty, !correct.isEmpty, wrong != correct else {
      return nil
    }

    return TranscriptCorrection(id: correction.id, wrong: wrong, correct: correct, type: type?.isEmpty == false ? type : nil)
  }

  private func revisionInstructions(
    kind: MeetingBlockKind,
    type: ReviewFeedbackType,
    comment: String,
    proposedText: String?
  ) -> String {
    var instructions = "Revise the \(reviewLabel(for: kind).lowercased()) block according to this feedback [\(type.rawValue)]: \(comment)"
    if let proposedText, !proposedText.isEmpty {
      instructions += " Proposed wording: \(proposedText)"
    }
    return instructions
  }

  private func transcriptForRevision(from session: NativeMeetingSession) -> String {
    if let organized = session.organizedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines), !organized.isEmpty {
      return organized
    }
    if let corrected = session.correctedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines), !corrected.isEmpty {
      return corrected
    }
    return session.liveTranscript
  }

  private func currentBlockQuote(for kind: MeetingBlockKind, session: NativeMeetingSession) -> String? {
    switch kind {
    case .executiveSummary:
      return session.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
    case .keyPoint:
      return session.keyPoints.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    case .actionItem:
      return session.actionItems.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    case .decision:
      return (session.decisions ?? []).map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    default:
      return nil
    }
  }

  func reviewLabel(for kind: MeetingBlockKind) -> String {
    switch kind {
    case .executiveSummary:
      return "Summary"
    case .keyPoint:
      return "Key Points"
    case .actionItem:
      return "Action Items"
    case .decision:
      return "Decisions"
    default:
      return "Block"
    }
  }

  private func exportAndSaveSession(_ session: NativeMeetingSession) async throws -> NativeMeetingSession {
    let exporter = NoteExporter(paths: paths)
    let notePath = try await exporter.export(
      note: NativeMeetingNote(
        title: session.title,
        startedAt: session.startedAt,
        endedAt: session.endedAt,
        transcript: session.correctedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
          ? session.correctedTranscript!
          : session.liveTranscript,
        liveTranscript: session.liveTranscript,
        summary: session.summary ?? "",
        organizedTranscript: session.organizedTranscript ?? "",
        keyPoints: session.keyPoints,
        actionItems: session.actionItems,
        decisions: session.decisions ?? [],
        openLoops: session.openLoops ?? [],
        risks: session.risks ?? [],
        participantPositions: session.participantPositions ?? [],
        projectLinks: session.projectLinks ?? [],
        relatedPeople: session.relatedPeople ?? [],
        dictionaryPath: session.dictionaryPath,
        audioFilePath: session.audioFilePath,
        provider: session.provider ?? "local",
        model: session.model ?? "manual-revision"
      )
    )

    var updatedSession = session
    updatedSession.exportedNotePath = notePath.path(percentEncoded: false)
    try await MeetingSessionStore(paths: paths).save(updatedSession)
    return updatedSession
  }

  private func replaceReviewComment(_ updated: ReviewComment, in comments: [ReviewComment]) -> [ReviewComment] {
    comments.map { existing in
      existing.id == updated.id ? updated : existing
    }
  }

  private func replaceRevisionRequest(_ updated: RevisionRequest, in requests: [RevisionRequest]) -> [RevisionRequest] {
    requests.map { existing in
      existing.id == updated.id ? updated : existing
    }
  }
}
