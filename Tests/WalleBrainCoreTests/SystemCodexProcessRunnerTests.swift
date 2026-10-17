import Foundation
import Testing
@testable import WalleBrainCore

/// Exercises the real process runner with system binaries (never the Codex CLI).
struct SystemCodexProcessRunnerTests {
  @Test
  func passesStandardInputAndCapturesOutput() async throws {
    let output = try await SystemCodexProcessRunner().run(
      invocation(executable: "/bin/cat", arguments: ["-"], stdin: "会议原文\n", timeout: .seconds(10))
    )

    #expect(output.exitCode == 0)
    #expect(output.standardOutput == "会议原文\n")
  }

  @Test
  func reportsNonZeroExitAndStandardError() async throws {
    let output = try await SystemCodexProcessRunner().run(
      invocation(executable: "/bin/cat", arguments: ["/nonexistent-wallebrain-file"], timeout: .seconds(10))
    )

    #expect(output.exitCode != 0)
    #expect(output.standardError.contains("nonexistent-wallebrain-file"))
  }

  @Test
  func terminatesProcessOnTimeout() async {
    let started = ContinuousClock.now
    await #expect(throws: CodexCLIError.timedOut(seconds: 0)) {
      try await SystemCodexProcessRunner().run(
        invocation(executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(300))
      )
    }
    #expect(ContinuousClock.now - started < .seconds(10))
  }

  @Test
  func terminatesProcessOnCancellation() async {
    let task = Task {
      try await SystemCodexProcessRunner().run(
        invocation(executable: "/bin/sleep", arguments: ["30"], timeout: .seconds(60))
      )
    }
    try? await Task.sleep(for: .milliseconds(300))
    task.cancel()

    let started = ContinuousClock.now
    let result = await task.result
    #expect(ContinuousClock.now - started < .seconds(10))
    #expect(throws: CancellationError.self) {
      try result.get()
    }
  }

  private func invocation(
    executable: String,
    arguments: [String],
    stdin: String? = nil,
    timeout: Duration
  ) -> CodexProcessInvocation {
    CodexProcessInvocation(
      executableURL: URL(fileURLWithPath: executable),
      arguments: arguments,
      environment: ["PATH": "/usr/bin:/bin"],
      workingDirectory: FileManager.default.temporaryDirectory,
      standardInput: stdin.map { Data($0.utf8) },
      timeout: timeout
    )
  }
}
