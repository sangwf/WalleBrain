import AVFoundation
import CoreMedia
import Darwin
import Foundation
import Speech
import WalleBrainCore

private enum BenchmarkProvider: String, Codable, CaseIterable, Sendable {
  case appleSpeech = "apple-speech"
  case openAIRealtime = "openai-realtime"

  var displayName: String {
    switch self {
    case .appleSpeech:
      return "Apple Speech"
    case .openAIRealtime:
      return "OpenAI Realtime"
    }
  }

  var modelName: String {
    switch self {
    case .appleSpeech:
      return "SpeechTranscriber"
    case .openAIRealtime:
      return RealtimeTranscriptionConfiguration.defaultModel
    }
  }
}

private struct DatasetSample: Decodable, Sendable {
  let id: String
  let source: String
  let audioFile: String
  let expectedTranscript: String
  let note: String?
}

private struct ProviderSampleResult: Codable {
  let sampleID: String
  let source: String
  let audioFile: String
  let expectedTranscript: String
  let provider: String
  let model: String
  let actualTranscript: String
  let normalizedExpected: String
  let normalizedActual: String
  let characterErrorRate: Double
  let characterAccuracy: Double
  let isExactMatch: Bool
  let expectedTermMentions: Int
  let matchedTermMentions: Int
  let error: String?
}

private struct ProviderSummary: Codable {
  let provider: String
  let model: String
  let sampleCount: Int
  let failedSampleCount: Int
  let averageCharacterErrorRate: Double
  let averageCharacterAccuracy: Double
  let exactMatchRate: Double
  let expectedTermMentions: Int
  let matchedTermMentions: Int
  let termRecall: Double?
}

private struct BenchmarkReport: Codable {
  let generatedAt: String
  let manifestPath: String
  let languageMode: String
  let dictionaryPath: String?
  let appliesDictionaryBias: Bool
  let providers: [String]
  let sampleCount: Int
  let summaries: [ProviderSummary]
  let results: [ProviderSampleResult]
}

private struct ParsedArguments {
  var manifestPath: String = "fixtures/datasets/manifest.jsonl"
  var providerSelection = "both"
  var limit: Int?
  var outputDirectory = "runtime/evaluations"
  var languageMode: TranscriptionLanguageMode = .chineseSimplified
  var sampleTimeoutSeconds: Double = 75
  var realtimeFinalDrainSeconds: Double = 6
  var dictionaryPath: String?
  var appliesDictionaryBias = true
}

private final class AudioBufferBox: @unchecked Sendable {
  let buffers: [AVAudioPCMBuffer]

  init(buffers: [AVAudioPCMBuffer]) {
    self.buffers = buffers
  }
}

private final class ConversionInputState: @unchecked Sendable {
  let sourceBuffer: AVAudioPCMBuffer
  var didProvideSource = false

  init(sourceBuffer: AVAudioPCMBuffer) {
    self.sourceBuffer = sourceBuffer
  }
}

private actor RealtimeResultCollector {
  private var completed: [RealtimeTranscriptionResult] = []
  private var latestPreview = ""

  func append(_ result: RealtimeTranscriptionResult) {
    if result.id == "realtime-streaming" {
      latestPreview = result.text
    } else {
      completed.append(result)
    }
  }

  func transcript() -> String {
    if !completed.isEmpty {
      return completed
        .map(\.text)
        .joined(separator: "\n")
    }

    return latestPreview
  }
}

@main
struct WalleBrainTranscriptionBenchmark {
  static func main() async {
    setbuf(stdout, nil)

    do {
      let args = try parseArguments(CommandLine.arguments)
      let manifestURL = URL(fileURLWithPath: args.manifestPath, relativeTo: projectRootURL())
        .standardizedFileURL
      let outputDirectory = URL(fileURLWithPath: args.outputDirectory, relativeTo: projectRootURL())
        .standardizedFileURL
      let samples = try loadSamples(from: manifestURL)
      let selectedSamples = args.limit.map { Array(samples.prefix($0)) } ?? samples
      let providers = try selectedProviders(from: args.providerSelection)
      let dictionaryURL = args.dictionaryPath.map {
        URL(fileURLWithPath: $0, relativeTo: projectRootURL()).standardizedFileURL
      }
      let vocabulary = try dictionaryURL.map {
        LiveSpeechVocabulary(dictionary: try TermDictionaryStore.parse(markdown: String(contentsOf: $0, encoding: .utf8)))
      } ?? .empty
      let recognitionVocabulary = args.appliesDictionaryBias ? vocabulary : .empty
      let generatedAt = ISO8601DateFormatter().string(from: Date())

      var results: [ProviderSampleResult] = []
      for sample in selectedSamples {
        let audioURL = URL(fileURLWithPath: sample.audioFile, relativeTo: manifestURL.deletingLastPathComponent())
          .standardizedFileURL

        for provider in providers {
          print("Transcribing \(sample.id) with \(provider.displayName)...")
          let result = await evaluate(
            sample: sample,
            audioURL: audioURL,
            provider: provider,
            languageMode: args.languageMode,
            vocabulary: recognitionVocabulary,
            termVocabulary: vocabulary,
            timeoutSeconds: args.sampleTimeoutSeconds,
            realtimeFinalDrainSeconds: args.realtimeFinalDrainSeconds
          )
          results.append(result)
        }
      }

      let report = BenchmarkReport(
        generatedAt: generatedAt,
        manifestPath: manifestURL.path(percentEncoded: false),
        languageMode: args.languageMode.rawValue,
        dictionaryPath: dictionaryURL?.path(percentEncoded: false),
        appliesDictionaryBias: args.appliesDictionaryBias && dictionaryURL != nil,
        providers: providers.map(\.rawValue),
        sampleCount: selectedSamples.count,
        summaries: providers.map { summary(for: $0, in: results) },
        results: results
      )

      try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
      let fileStem = generatedAt.replacingOccurrences(of: ":", with: "-")
      let jsonURL = outputDirectory.appending(path: "\(fileStem).transcription-benchmark.json")
      let markdownURL = outputDirectory.appending(path: "\(fileStem).transcription-benchmark.md")
      try writeJSON(report, to: jsonURL)
      try markdownReport(report).write(to: markdownURL, atomically: true, encoding: .utf8)

      print("")
      print(markdownSummary(report))
      print("")
      print("JSON: \(jsonURL.path(percentEncoded: false))")
      print("Markdown: \(markdownURL.path(percentEncoded: false))")
    } catch {
      fputs("BENCHMARK_ERROR \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  private static func evaluate(
    sample: DatasetSample,
    audioURL: URL,
    provider: BenchmarkProvider,
    languageMode: TranscriptionLanguageMode,
    vocabulary: LiveSpeechVocabulary,
    termVocabulary: LiveSpeechVocabulary,
    timeoutSeconds: Double,
    realtimeFinalDrainSeconds: Double
  ) async -> ProviderSampleResult {
    let transcript: String
    let model: String
    let errorMessage: String?

    do {
      switch provider {
      case .appleSpeech:
        (transcript, model) = try await withTimeout(seconds: timeoutSeconds) {
          try await transcribeWithAppleSpeech(audioURL: audioURL, languageMode: languageMode, vocabulary: vocabulary)
        }
      case .openAIRealtime:
        (transcript, model) = try await withTimeout(seconds: timeoutSeconds) {
          try await transcribeWithOpenAIRealtime(
            audioURL: audioURL,
            languageMode: languageMode,
            finalDrainSeconds: realtimeFinalDrainSeconds
          )
        }
      }
      errorMessage = nil
    } catch {
      transcript = ""
      model = provider.modelName
      errorMessage = error.localizedDescription
    }

    let normalizedExpected = TranscriptionEvaluationMetrics.normalizeTextForComparison(sample.expectedTranscript)
    let normalizedActual = TranscriptionEvaluationMetrics.normalizeTextForComparison(transcript)
    let termMentions = TranscriptionEvaluationMetrics.termMentionCounts(
      expected: sample.expectedTranscript,
      actual: transcript,
      terms: termVocabulary.dictionary.allTerms
    )
    return ProviderSampleResult(
      sampleID: sample.id,
      source: sample.source,
      audioFile: audioURL.path(percentEncoded: false),
      expectedTranscript: sample.expectedTranscript,
      provider: provider.displayName,
      model: model,
      actualTranscript: transcript,
      normalizedExpected: normalizedExpected,
      normalizedActual: normalizedActual,
      characterErrorRate: TranscriptionEvaluationMetrics.characterErrorRate(
        expected: sample.expectedTranscript,
        actual: transcript
      ),
      characterAccuracy: TranscriptionEvaluationMetrics.characterAccuracy(
        expected: sample.expectedTranscript,
        actual: transcript
      ),
      isExactMatch: TranscriptionEvaluationMetrics.isNormalizedExactMatch(
        expected: sample.expectedTranscript,
        actual: transcript
      ),
      expectedTermMentions: termMentions.expected,
      matchedTermMentions: termMentions.matched,
      error: errorMessage
    )
  }

  private static func transcribeWithAppleSpeech(
    audioURL: URL,
    languageMode: TranscriptionLanguageMode,
    vocabulary: LiveSpeechVocabulary
  ) async throws -> (transcript: String, model: String) {
    let localeIdentifier = languageMode.localeIdentifier ?? "zh_CN"
    let requestedLocale = Locale(identifier: localeIdentifier)
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) ?? requestedLocale
    let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)

    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await request.downloadAndInstall()
    }

    let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
      ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let stream = try audioStream(from: audioURL, targetFormat: analyzerFormat)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.prepareToAnalyze(in: analyzerFormat)
    // Mirror the live path: contextual strings on the analyzer, term repair on each result.
    if !vocabulary.contextualStrings.isEmpty {
      let context = AnalysisContext()
      context.contextualStrings[.general] = vocabulary.contextualStrings
      try await analyzer.setContext(context)
    }
    let collector = Task { () throws -> [ProviderTranscriptChunk] in
      var chunks: [ProviderTranscriptChunk] = []
      for try await result in transcriber.results {
        let startSeconds = result.range.start.seconds.isFinite ? result.range.start.seconds : 0
        let durationSeconds = result.range.duration.seconds.isFinite ? result.range.duration.seconds : 0
        let id = chunkID(startSeconds: startSeconds, durationSeconds: durationSeconds)
        let chunk = ProviderTranscriptChunk(
          id: id,
          startSeconds: startSeconds,
          durationSeconds: durationSeconds,
          text: vocabulary.termRepair.apply(to: String(result.text.characters))
        )
        chunks = mergedProviderChunks(chunks, with: chunk)
      }
      return chunks
    }

    try await analyzer.start(inputSequence: stream)
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let chunks = try await collector.value
    let model = vocabulary.contextualStrings.isEmpty ? "SpeechTranscriber" : "SpeechTranscriber + dictionary"
    return (liveTranscript(from: chunks), model)
  }

  private static func transcribeWithOpenAIRealtime(
    audioURL: URL,
    languageMode: TranscriptionLanguageMode,
    finalDrainSeconds: Double
  ) async throws -> (transcript: String, model: String) {
    let configuration = try RealtimeTranscriptionConfigurationResolver().resolve()
    let client = OpenAIRealtimeTranscriptionClient(
      configuration: configuration,
      finalReceiveDrain: .milliseconds(Int(finalDrainSeconds * 1_000))
    )
    let collector = RealtimeResultCollector()
    let stream = try audioStream(
      from: audioURL,
      targetFormat: OpenAIRealtimeTranscriptionClient.audioFormat,
      paceInRealtime: true
    )
    try await client.run(
      stream: stream,
      prompt: "",
      languageCode: languageMode.realtimeLanguageCode ?? "zh"
    ) { result in
      await collector.append(result)
    }
    return (await collector.transcript(), configuration.model)
  }

  private static func audioStream(
    from audioURL: URL,
    targetFormat: AVAudioFormat? = nil,
    paceInRealtime: Bool = false
  ) throws -> AsyncStream<AnalyzerInput> {
    let file = try AVAudioFile(forReading: audioURL)
    let format = file.processingFormat
    let frameCount = max(1, AVAudioFrameCount(format.sampleRate * 0.5))
    var buffers: [AVAudioPCMBuffer] = []

    while file.framePosition < file.length {
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw WalleBrainError.invalidResponse("Could not allocate audio buffer for \(audioURL.lastPathComponent).")
      }
      try file.read(into: buffer, frameCount: frameCount)
      if buffer.frameLength > 0 {
        if let targetFormat, let converted = convert(buffer, to: targetFormat) {
          buffers.append(converted)
        } else if targetFormat == nil {
          buffers.append(buffer)
        } else {
          throw WalleBrainError.invalidResponse("Could not convert audio buffer for \(audioURL.lastPathComponent).")
        }
      }
    }

    let box = AudioBufferBox(buffers: buffers)
    return AsyncStream { continuation in
      let task = Task {
        for buffer in box.buffers {
          if Task.isCancelled {
            break
          }
          continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: nil))
          if paceInRealtime {
            try? await Task.sleep(nanoseconds: durationNanoseconds(of: buffer))
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private static func convert(_ sourceBuffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    if formatsMatch(sourceBuffer.format, targetFormat) {
      return sourceBuffer
    }

    guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
      return nil
    }

    let frameCount = Int(sourceBuffer.frameLength)
    let targetCapacity = max(
      1,
      AVAudioFrameCount(
        ceil(Double(frameCount) * targetFormat.sampleRate / sourceBuffer.format.sampleRate) + 32
      )
    )
    guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
      return nil
    }

    let inputState = ConversionInputState(sourceBuffer: sourceBuffer)
    var conversionError: NSError?
    let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
      if inputState.didProvideSource {
        outStatus.pointee = .endOfStream
        return nil
      }

      inputState.didProvideSource = true
      outStatus.pointee = .haveData
      return inputState.sourceBuffer
    }

    guard conversionError == nil else {
      return nil
    }

    switch status {
    case .haveData, .inputRanDry, .endOfStream:
      return targetBuffer.frameLength > 0 ? targetBuffer : nil
    case .error:
      return nil
    @unknown default:
      return nil
    }
  }

  private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
    lhs.commonFormat == rhs.commonFormat
      && lhs.sampleRate == rhs.sampleRate
      && lhs.channelCount == rhs.channelCount
      && lhs.isInterleaved == rhs.isInterleaved
  }

  private static func durationNanoseconds(of buffer: AVAudioPCMBuffer) -> UInt64 {
    guard buffer.format.sampleRate > 0 else {
      return 0
    }
    return UInt64((Double(buffer.frameLength) / buffer.format.sampleRate) * 1_000_000_000)
  }

  private struct ProviderTranscriptChunk {
    let id: String
    let startSeconds: Double
    let durationSeconds: Double
    let text: String
  }

  private static func liveTranscript(from chunks: [ProviderTranscriptChunk]) -> String {
    chunks
      .sorted { left, right in
        if left.startSeconds == right.startSeconds {
          return left.durationSeconds < right.durationSeconds
        }
        return left.startSeconds < right.startSeconds
      }
      .map(\.text)
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  private static func mergedProviderChunks(
    _ chunks: [ProviderTranscriptChunk],
    with incoming: ProviderTranscriptChunk
  ) -> [ProviderTranscriptChunk] {
    let retained = chunks.filter { existing in
      !shouldReplaceProviderChunk(existing: existing, with: incoming)
    }
    return retained + [incoming]
  }

  private static func shouldReplaceProviderChunk(
    existing: ProviderTranscriptChunk,
    with incoming: ProviderTranscriptChunk
  ) -> Bool {
    if abs(existing.startSeconds - incoming.startSeconds) <= 0.05 {
      return true
    }

    let existingEnd = existing.startSeconds + max(existing.durationSeconds, 0)
    let incomingEnd = incoming.startSeconds + max(incoming.durationSeconds, 0)
    let overlapStart = max(existing.startSeconds, incoming.startSeconds)
    let overlapEnd = min(existingEnd, incomingEnd)
    return overlapEnd - overlapStart > 0.05
  }

  private static func chunkID(startSeconds: Double, durationSeconds: Double) -> String {
    String(format: "%.3f-%.3f", startSeconds, durationSeconds)
  }

  private static func summary(for provider: BenchmarkProvider, in results: [ProviderSampleResult]) -> ProviderSummary {
    let providerResults = results.filter { $0.provider == provider.displayName }
    let successful = providerResults.filter { $0.error == nil }
    let model = providerResults.first?.model ?? provider.modelName
    let expectedTerms = successful.map(\.expectedTermMentions).reduce(0, +)
    let matchedTerms = successful.map(\.matchedTermMentions).reduce(0, +)
    return ProviderSummary(
      provider: provider.displayName,
      model: model,
      sampleCount: providerResults.count,
      failedSampleCount: providerResults.count - successful.count,
      averageCharacterErrorRate: average(successful.map(\.characterErrorRate)),
      averageCharacterAccuracy: average(successful.map(\.characterAccuracy)),
      exactMatchRate: ratio(successful.map(\.isExactMatch)),
      expectedTermMentions: expectedTerms,
      matchedTermMentions: matchedTerms,
      termRecall: expectedTerms > 0 ? Double(matchedTerms) / Double(expectedTerms) : nil
    )
  }

  private static func average(_ values: [Double]) -> Double {
    guard !values.isEmpty else {
      return 0
    }
    return values.reduce(0, +) / Double(values.count)
  }

  private static func ratio(_ values: [Bool]) -> Double {
    guard !values.isEmpty else {
      return 0
    }
    return Double(values.filter { $0 }.count) / Double(values.count)
  }

  private static func loadSamples(from manifestURL: URL) throws -> [DatasetSample] {
    let raw = try String(contentsOf: manifestURL, encoding: .utf8)
    return try raw
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map { line in
        guard let data = line.data(using: .utf8) else {
          throw WalleBrainError.invalidResponse("Manifest line is not UTF-8.")
        }
        return try JSONDecoder().decode(DatasetSample.self, from: data)
      }
  }

  private static func selectedProviders(from selection: String) throws -> [BenchmarkProvider] {
    switch selection {
    case "both":
      return BenchmarkProvider.allCases
    case "apple", "apple-speech", "local":
      return [.appleSpeech]
    case "openai", "openai-realtime", "realtime", "high-quality":
      return [.openAIRealtime]
    default:
      throw WalleBrainError.invalidResponse("Unknown provider '\(selection)'. Use both, apple-speech, or openai-realtime.")
    }
  }

  private static func parseArguments(_ arguments: [String]) throws -> ParsedArguments {
    var parsed = ParsedArguments()
    var index = 1

    while index < arguments.count {
      let argument = arguments[index]
      let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil

      switch argument {
      case "--manifest":
        guard let next else {
          throw WalleBrainError.invalidResponse("--manifest requires a path.")
        }
        parsed.manifestPath = next
        index += 2
      case "--provider":
        guard let next else {
          throw WalleBrainError.invalidResponse("--provider requires both, apple-speech, or openai-realtime.")
        }
        parsed.providerSelection = next
        index += 2
      case "--limit":
        guard let next, let limit = Int(next), limit > 0 else {
          throw WalleBrainError.invalidResponse("--limit requires a positive integer.")
        }
        parsed.limit = limit
        index += 2
      case "--output-dir":
        guard let next else {
          throw WalleBrainError.invalidResponse("--output-dir requires a path.")
        }
        parsed.outputDirectory = next
        index += 2
      case "--language":
        guard let next else {
          throw WalleBrainError.invalidResponse("--language requires zh, en, or auto.")
        }
        parsed.languageMode = try parseLanguageMode(next)
        index += 2
      case "--sample-timeout":
        guard let next, let seconds = Double(next), seconds > 0 else {
          throw WalleBrainError.invalidResponse("--sample-timeout requires a positive number of seconds.")
        }
        parsed.sampleTimeoutSeconds = seconds
        index += 2
      case "--realtime-final-drain":
        guard let next, let seconds = Double(next), seconds >= 0 else {
          throw WalleBrainError.invalidResponse("--realtime-final-drain requires a non-negative number of seconds.")
        }
        parsed.realtimeFinalDrainSeconds = seconds
        index += 2
      case "--dictionary":
        guard let next else {
          throw WalleBrainError.invalidResponse("--dictionary requires a Business Dictionary markdown path.")
        }
        parsed.dictionaryPath = next
        index += 2
      case "--measure-terms-only":
        parsed.appliesDictionaryBias = false
        index += 1
      case "--help", "-h":
        printUsage()
        exit(0)
      default:
        throw WalleBrainError.invalidResponse("Unknown argument '\(argument)'.")
      }
    }

    return parsed
  }

  private static func parseLanguageMode(_ value: String) throws -> TranscriptionLanguageMode {
    switch value {
    case "zh", "zh_CN", "chinese", "chineseSimplified":
      return .chineseSimplified
    case "en", "en_US", "english", "englishUS":
      return .englishUS
    case "auto", "automatic":
      return .automatic
    default:
      throw WalleBrainError.invalidResponse("Unknown language '\(value)'. Use zh, en, or auto.")
    }
  }

  private static func writeJSON(_ report: BenchmarkReport, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: url, options: .atomic)
  }

  private static func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
        throw WalleBrainError.invalidResponse("Timed out after \(String(format: "%.1f", seconds)) seconds.")
      }

      guard let result = try await group.next() else {
        throw WalleBrainError.invalidResponse("Timed out before transcription started.")
      }
      group.cancelAll()
      return result
    }
  }

  private static func markdownSummary(_ report: BenchmarkReport) -> String {
    var lines = [
      "| Provider | Samples | Failed | Avg CER | Avg Accuracy | Exact Match | Term Recall |",
      "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for summary in report.summaries {
      lines.append(
        "| \(summary.provider) | \(summary.sampleCount) | \(summary.failedSampleCount) | \(percent(summary.averageCharacterErrorRate)) | \(percent(summary.averageCharacterAccuracy)) | \(percent(summary.exactMatchRate)) | \(termRecallLabel(summary)) |"
      )
    }
    return lines.joined(separator: "\n")
  }

  private static func markdownReport(_ report: BenchmarkReport) -> String {
    var lines = [
      "# Transcription Benchmark",
      "",
      "- Generated: \(report.generatedAt)",
      "- Manifest: `\(report.manifestPath)`",
      "- Language: `\(report.languageMode)`",
      "- Dictionary: \(report.dictionaryPath.map { "`\($0)`" } ?? "none") (bias \(report.appliesDictionaryBias ? "applied" : "not applied"))",
      "",
      markdownSummary(report),
      "",
      "## Samples",
      "",
      "| Sample | Provider | Expected | Actual | CER | Error |",
      "|---|---|---|---|---:|---|",
    ]

    for result in report.results {
      lines.append(
        "| \(escapeMarkdown(result.sampleID)) | \(escapeMarkdown(result.provider)) | \(escapeMarkdown(result.expectedTranscript)) | \(escapeMarkdown(result.actualTranscript)) | \(percent(result.characterErrorRate)) | \(escapeMarkdown(result.error ?? "")) |"
      )
    }

    lines.append("")
    return lines.joined(separator: "\n")
  }

  private static func termRecallLabel(_ summary: ProviderSummary) -> String {
    guard let recall = summary.termRecall else {
      return "-"
    }
    return "\(percent(recall)) (\(summary.matchedTermMentions)/\(summary.expectedTermMentions))"
  }

  private static func percent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
  }

  private static func escapeMarkdown(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\n", with: "<br>")
      .replacingOccurrences(of: "|", with: "\\|")
  }

  private static func printUsage() {
    print("""
    Usage:
      WalleBrainTranscriptionBenchmark [--manifest fixtures/datasets/manifest.jsonl] [--provider both|apple-speech|openai-realtime] [--language zh|en|auto] [--limit N] [--sample-timeout 75] [--realtime-final-drain 6] [--dictionary "runtime/native/Dictionary/Business Dictionary.md" [--measure-terms-only]] [--output-dir runtime/evaluations]

    Notes:
      - openai-realtime requires OPENAI_API_KEY.
      - --dictionary applies the live vocabulary (contextual strings + term repair) to apple-speech and reports term recall.
      - --measure-terms-only reports term recall for the dictionary without applying it (the "before" baseline).
      - apple-speech requires macOS Speech recognition permission; run from an app bundle if TCC rejects a raw CLI.
    """)
  }

  private static func projectRootURL() -> URL {
    RuntimePaths.defaultBaseDirectory()
  }
}
