import Foundation

public struct CLIProcessInvocation: Sendable, Equatable {
  public var executableURL: URL
  public var arguments: [String]
  public var environment: [String: String]
  public var workingDirectory: URL
  public var standardInput: Data?
  public var timeout: Duration

  public init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL,
    standardInput: Data? = nil,
    timeout: Duration
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.standardInput = standardInput
    self.timeout = timeout
  }
}

public struct CLIProcessOutput: Sendable, Equatable {
  public var exitCode: Int32
  public var standardOutput: String
  public var standardError: String

  public init(exitCode: Int32, standardOutput: String, standardError: String) {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

public protocol CLIProcessRunning: Sendable {
  /// Runs the invocation to completion. Throws `LocalCLIError.timedOut` when the timeout elapses and
  /// `CancellationError` when the calling task is cancelled; the child process is terminated in both cases.
  func run(_ invocation: CLIProcessInvocation) async throws -> CLIProcessOutput
}

/// Runs a child process directly (no shell). stdin/stdout/stderr go through temporary files rather than
/// pipes so large transcripts can never deadlock on a full pipe buffer.
public struct SystemCLIProcessRunner: CLIProcessRunning {
  public init() {}

  public func run(_ invocation: CLIProcessInvocation) async throws -> CLIProcessOutput {
    let fileManager = FileManager.default
    let ioDirectory = fileManager.temporaryDirectory
      .appending(path: "WalleBrainCodexIO-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: ioDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: ioDirectory) }

    let stdinURL = ioDirectory.appending(path: "stdin", directoryHint: .notDirectory)
    let stdoutURL = ioDirectory.appending(path: "stdout", directoryHint: .notDirectory)
    let stderrURL = ioDirectory.appending(path: "stderr", directoryHint: .notDirectory)
    try (invocation.standardInput ?? Data()).write(to: stdinURL)
    try Data().write(to: stdoutURL)
    try Data().write(to: stderrURL)

    let stdinHandle = try FileHandle(forReadingFrom: stdinURL)
    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    defer {
      try? stdinHandle.close()
      try? stdoutHandle.close()
      try? stderrHandle.close()
    }

    let process = Process()
    process.executableURL = invocation.executableURL
    process.arguments = invocation.arguments
    process.environment = invocation.environment
    process.currentDirectoryURL = invocation.workingDirectory
    process.standardInput = stdinHandle
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle

    let handle = RunningProcessHandle(process: process)
    let timeoutTask = Task.detached {
      try await Task.sleep(for: invocation.timeout)
      handle.stop(.timedOut)
    }
    defer { timeoutTask.cancel() }

    let exitCode: Int32 = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { finished in
          continuation.resume(returning: finished.terminationStatus)
        }
        do {
          guard try handle.launch() else {
            process.terminationHandler = nil
            continuation.resume(throwing: CancellationError())
            return
          }
        } catch {
          process.terminationHandler = nil
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      handle.stop(.cancelled)
    }

    switch handle.stopReason {
    case .timedOut:
      throw LocalCLIError.timedOut(seconds: Int(invocation.timeout.components.seconds))
    case .cancelled:
      throw CancellationError()
    case nil:
      break
    }

    return CLIProcessOutput(
      exitCode: exitCode,
      standardOutput: String(decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(), as: UTF8.self),
      standardError: String(decoding: (try? Data(contentsOf: stderrURL)) ?? Data(), as: UTF8.self)
    )
  }
}

private final class RunningProcessHandle: @unchecked Sendable {
  enum StopReason {
    case cancelled
    case timedOut
  }

  private let lock = NSLock()
  private let process: Process
  private var launched = false
  private var requestedStop: StopReason?

  init(process: Process) {
    self.process = process
  }

  var stopReason: StopReason? {
    lock.withLock { requestedStop }
  }

  /// Returns false without launching when a stop was requested before launch.
  func launch() throws -> Bool {
    try lock.withLock {
      guard requestedStop == nil else {
        return false
      }
      try process.run()
      launched = true
      return true
    }
  }

  func stop(_ reason: StopReason) {
    let pid: Int32? = lock.withLock {
      if requestedStop == nil {
        requestedStop = reason
      }
      guard launched, process.isRunning else {
        return nil
      }
      process.terminate()
      return process.processIdentifier
    }

    guard let pid else {
      return
    }
    // Escalate if the child ignores SIGTERM.
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
      if lock.withLock({ process.isRunning }) {
        kill(pid, SIGKILL)
      }
    }
  }
}
