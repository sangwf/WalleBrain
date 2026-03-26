import AVFoundation
import Darwin
import Foundation
import Speech
import WalleBrainCore

@main
struct WalleBrainSpeechProbe {
  static func main() async {
    setbuf(stdout, nil)

    do {
      let arguments = CommandLine.arguments
      let audioPath = argumentValue(named: "--audio", in: arguments)
        ?? defaultFixturePath()

      let paths = RuntimePaths()
      let dictionaryStore = TermDictionaryStore(paths: paths)
      let compiler = CustomLanguageModelCompiler(paths: paths)
      let dictionary = try await dictionaryStore.loadDictionary()
      let assets = try await compiler.compile(dictionary: dictionary)
      let configuration = await compiler.configuration(for: assets)

      let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN"))
        ?? Locale(identifier: "zh_CN")

      let transcriber = DictationTranscriber(
        locale: locale,
        contentHints: [.customizedLanguage(modelConfiguration: configuration)],
        transcriptionOptions: [],
        reportingOptions: [.volatileResults],
        attributeOptions: []
      )

      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
      }

      let audioURL = URL(fileURLWithPath: audioPath)
      let file = try AVAudioFile(forReading: audioURL)
      let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
      try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
      print("START_DONE")

      while true {
        try await Task.sleep(for: .seconds(60))
      }
    } catch {
      print("PROBE_ERROR \(error.localizedDescription)")
      exit(1)
    }
  }

  private static func argumentValue(named name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
      return nil
    }

    return arguments[index + 1]
  }

  private static func defaultFixturePath() -> String {
    let candidates = [
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "fixtures/datasets/magicdata_dev_subset/37_5622_20170913203118.wav"),
      URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "fixtures/datasets/magicdata_dev_subset/37_5622_20170913203118.wav"),
    ]

    for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
      return candidate.path(percentEncoded: false)
    }

    return candidates[0].path(percentEncoded: false)
  }
}
