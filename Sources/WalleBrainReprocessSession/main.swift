import Foundation
import WalleBrainCore

@main
struct WalleBrainReprocessSession {
  static func main() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
      fputs("Usage: swift run WalleBrainReprocessSession <session-json-path>\n", stderr)
      Foundation.exit(2)
    }

    let sessionURL = URL(fileURLWithPath: arguments[1])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let data = try Data(contentsOf: sessionURL)
    var session = try decoder.decode(NativeMeetingSession.self, from: data)

    let paths = RuntimePaths()
    session = try await MeetingPostProcessor(paths: paths).process(session)

    try await MeetingSessionStore(paths: paths).save(session)

    let output: [String: String] = [
      "status": session.status.rawValue,
      "model": session.model ?? "",
      "notePath": session.exportedNotePath ?? "",
      "error": session.errorMessage ?? ""
    ]
    let outputData = try encoder.encode(output)
    FileHandle.standardOutput.write(outputData)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
