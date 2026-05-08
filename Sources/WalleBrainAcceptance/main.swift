import Foundation
import WalleBrainCore

@main
struct WalleBrainAcceptance {
  static func main() async {
    let baseURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let paths = RuntimePaths(baseDirectory: baseURL)
    var report: [String: Any] = [
      "generatedAt": ISO8601DateFormatter().string(from: Date()),
    ]

    do {
      let buildOutput = try runCommand(
        launchPath: "/usr/bin/env",
        arguments: ["swift", "build"],
        currentDirectoryURL: baseURL
      )
      report["build"] = [
        "passed": true,
        "stdout": buildOutput.stdout,
      ]

      let appBundle = try buildBundle(
        product: "WalleBrainApp",
        bundleName: "WalleBrain",
        bundleID: "com.wallebrain.app",
        baseURL: baseURL
      )
      let appLaunchLaunched = try runBundleLaunchSmoke(appURL: appBundle)
      report["bundle"] = [
        "passed": hasUsageDescription(in: appBundle, key: "NSMicrophoneUsageDescription")
          && hasUsageDescription(in: appBundle, key: "NSAudioCaptureUsageDescription")
          && hasUsageDescription(in: appBundle, key: "NSSpeechRecognitionUsageDescription")
          && appLaunchLaunched,
        "path": appBundle.path(percentEncoded: false),
        "hasMicrophoneUsageDescription": hasUsageDescription(in: appBundle, key: "NSMicrophoneUsageDescription"),
        "hasAudioCaptureUsageDescription": hasUsageDescription(in: appBundle, key: "NSAudioCaptureUsageDescription"),
        "hasSpeechUsageDescription": hasUsageDescription(in: appBundle, key: "NSSpeechRecognitionUsageDescription"),
        "launchSmoke": appLaunchLaunched,
      ]

      let smokeBundle = try buildBundle(
        product: "WalleBrainRealMeetingSmoke",
        bundleName: "WalleBrainSmoke",
        bundleID: "com.wallebrain.smoke",
        baseURL: baseURL
      )

      let harness = FixtureHarness(paths: paths)
      let harnessResult = try await harness.run(transcript: "高德地图")

      let probeResult = try runSpeechProbe(baseURL: baseURL)
      report["speechProbe"] = [
        "passed": probeResult.sawStartDone,
        "sawStartDone": probeResult.sawStartDone,
        "stdout": probeResult.stdout,
      ]
      guard probeResult.sawStartDone else {
        throw WalleBrainError.invalidResponse("Speech probe did not report START_DONE.")
      }

      let realSmoke = try await runMeetingSmoke(
        appURL: smokeBundle,
        baseURL: baseURL,
        title: "Native Real Smoke",
        input: "microphone",
        duration: 2
      )
      guard realSmoke.status == .exported else {
        throw WalleBrainError.invalidResponse("Real meeting smoke did not export successfully.")
      }
      report["realMeetingSmoke"] = [
        "passed": realSmoke.status == .exported,
        "status": realSmoke.status.rawValue,
        "input": realSmoke.selectedInput?.name ?? "",
        "audioFile": realSmoke.audioFilePath,
        "noteFile": realSmoke.exportedNotePath ?? "",
        "provider": realSmoke.provider ?? "",
        "model": realSmoke.model ?? "",
        "transcriptLength": realSmoke.liveTranscript.count,
      ]

      let systemAudioSmoke = try await runMeetingSmoke(
        appURL: smokeBundle,
        baseURL: baseURL,
        title: "Native System Audio Smoke",
        input: "system-audio",
        duration: 2,
        fixtureSpeech: "你好，这是 WalleBrain 的系统音频录写测试。",
        requireAudioFile: false
      )

      let systemAudioCheck: [String: Any]
      switch systemAudioSmoke.status {
      case .exported:
        guard !systemAudioSmoke.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw WalleBrainError.invalidResponse("System audio smoke exported without any live transcript.")
        }
        systemAudioCheck = [
          "status": systemAudioSmoke.status.rawValue,
          "input": systemAudioSmoke.selectedInput?.name ?? "",
          "audioFile": systemAudioSmoke.audioFilePath,
          "noteFile": systemAudioSmoke.exportedNotePath ?? "",
          "transcriptLength": systemAudioSmoke.liveTranscript.count,
          "permissionRequired": false,
        ]
      case .failed:
        guard systemAudioSmoke.errorMessage?.contains("System Audio") == true else {
          throw WalleBrainError.invalidResponse("System audio smoke failed unexpectedly: \(systemAudioSmoke.errorMessage ?? "unknown error")")
        }
        systemAudioCheck = [
          "status": systemAudioSmoke.status.rawValue,
          "input": systemAudioSmoke.selectedInput?.name ?? "",
          "error": systemAudioSmoke.errorMessage ?? "",
          "permissionRequired": true,
        ]
      default:
        throw WalleBrainError.invalidResponse("System audio smoke did not reach an exported or failed terminal state.")
      }

      let structuredSessionData = try Data(contentsOf: URL(fileURLWithPath: realSmoke.sessionJSONPath))
      let structuredSessionKeys = try AcceptanceHarness.requiredStructuredKeysPresent(in: structuredSessionData)
      let exportedNotePath = realSmoke.exportedNotePath ?? ""
      let exportedNoteText = try String(contentsOfFile: exportedNotePath, encoding: .utf8)
      let exportedNoteSections = AcceptanceHarness.requiredStructuredSectionsPresent(in: exportedNoteText)
      report["structuredDraft"] = [
        "passed": structuredSessionKeys.values.allSatisfy { $0 } && exportedNoteSections.values.allSatisfy { $0 },
        "sessionKeys": structuredSessionKeys,
        "noteSections": exportedNoteSections,
      ]

      let legacySessionDecodePassed = try AcceptanceHarness.decodeLegacySessionCheck()
      report["legacySessionDecode"] = [
        "passed": legacySessionDecodePassed,
      ]

      let reviewRoundTrip = AcceptanceHarness.reviewRoundTripCheck()
      report["reviewRoundTrip"] = [
        "passed": reviewRoundTrip.passed,
        "before": reviewRoundTrip.before,
        "after": reviewRoundTrip.after,
      ]

      let fixtureSuite = try AcceptanceHarness.loadStructuredNoteFixtureSuite(baseDirectory: baseURL)
      let dictionary = try await TermDictionaryStore(paths: paths).loadDictionary()
      let fixtureConfiguration = fixtureEvaluationConfiguration()
      let realFixtureClient = try LLMChatClient(configuration: fixtureConfiguration)
      let fixtureEval = try await AcceptanceHarness.evaluateFixtureSuiteReal(
        fixtureSuite,
        dictionary: dictionary,
        client: realFixtureClient
      )
      report["fixtureEval"] = [
        "passed": fixtureEval.passed,
        "modelsReference": fixtureConfiguration.modelsReference,
        "cases": fixtureEval.cases.map {
          var item: [String: Any] = [
            "id": $0.id,
            "passed": $0.passed,
            "errors": $0.errors,
          ]
          if let diagnostics = $0.diagnostics {
            item["diagnostics"] = [
              "summary": diagnostics.summary,
              "keyPoints": diagnostics.keyPoints,
              "actionItems": diagnostics.actionItems,
              "decisions": diagnostics.decisions,
              "openLoops": diagnostics.openLoops,
              "projectLinks": diagnostics.projectLinks,
            ]
          }
          return item
        },
      ]

      let fixtureNoteText = try String(contentsOf: harnessResult.notePath, encoding: .utf8)
      let fixtureNoteSections = AcceptanceHarness.requiredStructuredSectionsPresent(in: fixtureNoteText)
      report["export"] = [
        "passed": FileManager.default.fileExists(atPath: exportedNotePath)
          && FileManager.default.fileExists(atPath: harnessResult.notePath.path(percentEncoded: false))
          && fixtureNoteSections.values.allSatisfy { $0 },
        "realMeetingNotePath": exportedNotePath,
        "fixtureNotePath": harnessResult.notePath.path(percentEncoded: false),
        "fixtureNoteSections": fixtureNoteSections,
      ]

      report["artifacts"] = [
        "dictionaryPath": harnessResult.dictionaryPath.path(percentEncoded: false),
        "languageModel": harnessResult.assets.languageModelURL.path(percentEncoded: false),
        "vocabulary": harnessResult.assets.vocabularyURL.path(percentEncoded: false),
        "systemAudioSmoke": systemAudioCheck,
        "llmResult": [
          "provider": harnessResult.llmResult.provider,
          "model": harnessResult.llmResult.model,
          "summary": harnessResult.llmResult.summary,
        ],
      ]

      try paths.ensureDirectories()
      let reportURL = try writeReport(report, paths: paths)
      let overallPassed = overallPass(from: report)

      print(
        String(
          data: try JSONSerialization.data(
            withJSONObject: [
              "reportPath": reportURL.path(percentEncoded: false),
              "passed": overallPassed,
              "speechProbe": probeResult.sawStartDone,
              "fixtureNotePath": harnessResult.notePath.path(percentEncoded: false),
              "realMeetingNotePath": realSmoke.exportedNotePath ?? "",
              "realMeetingStatus": realSmoke.status.rawValue,
              "systemAudioStatus": systemAudioSmoke.status.rawValue,
            ],
            options: [.prettyPrinted, .sortedKeys]
          ),
          encoding: .utf8
        ) ?? "{}"
      )

      if !overallPassed {
        exit(1)
      }
    } catch {
      report["fatalError"] = error.localizedDescription
      if (try? paths.ensureDirectories()) != nil {
        _ = try? writeReport(report, paths: paths)
      }
      fputs("ACCEPTANCE_ERROR \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  private static func overallPass(from report: [String: Any]) -> Bool {
    [
      "build",
      "bundle",
      "speechProbe",
      "realMeetingSmoke",
      "structuredDraft",
      "legacySessionDecode",
      "reviewRoundTrip",
      "fixtureEval",
      "export",
    ].allSatisfy { key in
      (report[key] as? [String: Any])?["passed"] as? Bool == true
    }
  }

  private static func writeReport(_ report: [String: Any], paths: RuntimePaths) throws -> URL {
    try paths.ensureDirectories()
    let reportURL = paths.nativeAcceptanceDirectory.appending(path: "\(Self.timestamp()).acceptance.json", directoryHint: .notDirectory)
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: reportURL)
    return reportURL
  }

  private static func buildBundle(
    product: String,
    bundleName: String,
    bundleID: String,
    baseURL: URL
  ) throws -> URL {
    let output = try runCommand(
      launchPath: "/usr/bin/env",
      arguments: ["./scripts/build_native_bundle.sh", product, bundleName, bundleID],
      currentDirectoryURL: baseURL
    )

    guard let path = output.stdout.components(separatedBy: .newlines).last(where: { $0.hasSuffix(".app") }) else {
      throw WalleBrainError.invalidResponse("Bundle build did not output an app path for \(product).")
    }

    return URL(fileURLWithPath: path)
  }

  private static func runBundleLaunchSmoke(appURL: URL) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["open", "-n", appURL.path(percentEncoded: false)]

    try process.run()
    process.waitUntilExit()
    Thread.sleep(forTimeInterval: 3)

    let launched = isProcessRunning(matching: appURL.appending(path: "Contents/MacOS/WalleBrainApp").path(percentEncoded: false))
    if launched {
      _ = try? runCommand(
        launchPath: "/usr/bin/env",
        arguments: ["pkill", "-f", appURL.appending(path: "Contents/MacOS/WalleBrainApp").path(percentEncoded: false)],
        currentDirectoryURL: appURL.deletingLastPathComponent()
      )
    }

    return launched
  }

  private static func runSpeechProbe(baseURL: URL) throws -> (sawStartDone: Bool, stdout: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "swift", "run", "WalleBrainSpeechProbe",
      "--audio", baseURL.appending(path: "fixtures/datasets/magicdata_dev_subset/37_5622_20170913203118.wav").path(percentEncoded: false),
    ]
    process.currentDirectoryURL = baseURL

    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stdoutPipe

    try process.run()

    let deadline = Date().addingTimeInterval(20)
    var captured = ""

    while Date() < deadline {
      let chunk = stdoutPipe.fileHandleForReading.availableData
      if !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) {
        captured += text
        if captured.contains("START_DONE") {
          process.terminate()
          return (true, captured)
        }
      }

      if !process.isRunning {
        break
      }

      Thread.sleep(forTimeInterval: 0.25)
    }

    let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    if !remaining.isEmpty, let text = String(data: remaining, encoding: .utf8) {
      captured += text
    }

    if process.isRunning {
      process.terminate()
    }

    return (captured.contains("START_DONE"), captured)
  }

  private static func runMeetingSmoke(
    appURL: URL,
    baseURL: URL,
    title: String,
    input: String,
    duration: Double,
    fixtureSpeech: String? = nil,
    requireAudioFile: Bool = true
  ) async throws -> NativeMeetingSession {
    let startTime = Date()
    _ = try runCommand(
      launchPath: "/usr/bin/env",
      arguments: [
        "open", "-n", appURL.path(percentEncoded: false), "--args",
        "--duration", String(duration),
        "--title", title,
        "--input", input,
      ] + (fixtureSpeech.map { ["--fixture-speech", $0] } ?? []),
      currentDirectoryURL: baseURL
    )

    let sessionDirectory = baseURL.appending(path: "runtime/native/MeetingSessions", directoryHint: .isDirectory)
    let reportsDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      if let crash = try newestCrashReport(after: startTime, reportsDirectory: reportsDirectory) {
        throw WalleBrainError.invalidResponse("Meeting smoke crashed: \(crash.lastPathComponent)")
      }

      if let sessionURL = try newestSession(
        after: startTime,
        title: title,
        sessionsDirectory: sessionDirectory
      ) {
        let data = try Data(contentsOf: sessionURL)
        let session = try decoder.decode(NativeMeetingSession.self, from: data)
        if session.status == .exported {
          if requireAudioFile, FileManager.default.fileExists(atPath: session.audioFilePath) == false {
            // Continue waiting for the audio artifact when the smoke requires one.
          } else {
            return session
          }
        }
        if session.status == .failed {
          return session
        }
      }

      try await Task.sleep(for: .milliseconds(500))
    }

    throw WalleBrainError.invalidResponse("Meeting smoke did not reach a terminal state before timeout.")
  }

  private static func newestSession(after date: Date, title: String, sessionsDirectory: URL) throws -> URL? {
    let files = try FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasSuffix("\(title).session.json") }
      .sorted { left, right in
        let leftDate = fileModificationDate(for: left)
        let rightDate = fileModificationDate(for: right)
        return leftDate > rightDate
      }

    guard let latest = files.first else {
      return nil
    }

    let modified = fileModificationDate(for: latest)
    return modified >= date.addingTimeInterval(-1) ? latest : nil
  }

  private static func newestCrashReport(after date: Date, reportsDirectory: URL) throws -> URL? {
    let files = try FileManager.default.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: nil)
      .filter {
        ($0.lastPathComponent.hasPrefix("WalleBrainRealMeetingSmoke-")
          || $0.lastPathComponent.hasPrefix("WalleBrainApp-"))
          && $0.pathExtension == "ips"
      }
      .sorted { left, right in
        fileModificationDate(for: left) > fileModificationDate(for: right)
      }

    return files.first(where: {
      fileModificationDate(for: $0) >= date.addingTimeInterval(-1)
    })
  }

  private static func fileModificationDate(for url: URL) -> Date {
    let path = url.path(percentEncoded: false)
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return attributes?[.modificationDate] as? Date ?? .distantPast
  }

  private static func isProcessRunning(matching pattern: String) -> Bool {
    (try? runCommand(
      launchPath: "/usr/bin/env",
      arguments: ["pgrep", "-f", pattern],
      currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    )) != nil
  }

  private static func hasUsageDescription(in appURL: URL, key: String) -> Bool {
    let infoURL = appURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
    guard
      let data = try? Data(contentsOf: infoURL),
      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
      let value = plist[key] as? String
    else {
      return false
    }

    return !value.isEmpty
  }

  private static func runCommand(
    launchPath: String,
    arguments: [String],
    currentDirectoryURL: URL,
  ) throws -> (stdout: String, status: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(decoding: data, as: UTF8.self)

    guard process.terminationStatus == 0 else {
      throw WalleBrainError.invalidResponse(stdout)
    }

    return (stdout, process.terminationStatus)
  }

  private static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
  }

  private static func fixtureEvaluationConfiguration() -> ModelConfiguration {
    let stored = ModelConfigurationStore().load()
    return ModelConfiguration(
      baseURLReference: stored.baseURLReference,
      apiKeyReference: stored.apiKeyReference,
      modelsReference: "gemini-3-flash-preview"
    )
  }
}
