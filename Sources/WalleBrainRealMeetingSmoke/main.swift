import Foundation
import WalleBrainCore

actor SmokeState {
  private(set) var latest: NativeMeetingSession?

  func update(_ session: NativeMeetingSession) {
    latest = session
  }
}

@main
struct WalleBrainRealMeetingSmoke {
  static func main() async {
    do {
      let duration = argumentValue(named: "--duration").flatMap(Double.init) ?? 3
      let title = argumentValue(named: "--title") ?? "Native Real Smoke"
      let inputMode = argumentValue(named: "--input") ?? "mixed"
      let fixtureSpeech = argumentValue(named: "--fixture-speech") ?? "你好，这是 WalleBrain 的系统音频录写测试。"
      let state = SmokeState()
      let coordinator = LiveMeetingCoordinator(paths: RuntimePaths()) { session in
        await state.update(session)
      }

      let inputs = await coordinator.availableInputs()
      let selectedInput = selectInput(mode: inputMode, from: inputs)

      try await coordinator.startMeeting(
        title: title,
        mode: .normal,
        preferredInputID: selectedInput?.id
      )
      if let selectedInput, AudioInputCatalog.isSystemAudioInput(id: selectedInput.id) {
        try playSystemAudioFixture(text: fixtureSpeech)
        try await Task.sleep(for: .seconds(1))
      } else {
        try await Task.sleep(for: .seconds(duration))
      }
      try await coordinator.stopMeetingAndProcess()

      guard let latest = await state.latest else {
        throw WalleBrainError.invalidResponse("Smoke run did not produce a session.")
      }

      let payload: [String: Any] = [
        "status": latest.status.rawValue,
        "inputCount": inputs.count,
        "selectedInput": latest.selectedInput?.name ?? "",
        "audioFile": latest.audioFilePath,
        "noteFile": latest.exportedNotePath ?? "",
        "transcriptLength": latest.liveTranscript.count,
        "model": latest.model ?? "",
      ]

      let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      print(String(decoding: data, as: UTF8.self))
    } catch {
      fputs("REAL_MEETING_SMOKE_ERROR \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  private static func argumentValue(named name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
      return nil
    }

    return arguments[index + 1]
  }

  private static func playSystemAudioFixture(text: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = [text]
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw WalleBrainError.invalidResponse("System audio fixture playback failed.")
    }
  }

  private static func selectInput(mode: String, from inputs: [AudioInputDevice]) -> AudioInputDevice? {
    switch mode {
    case "system-audio":
      return inputs.first(where: { AudioInputCatalog.isSystemAudioInput(id: $0.id) })
    case "microphone":
      return inputs.first(where: {
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
    case "mixed":
      fallthrough
    default:
      return AudioInputCatalog.preferredInput(from: inputs)
    }
  }
}
