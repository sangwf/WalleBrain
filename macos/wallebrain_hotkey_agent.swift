import AppKit
import ApplicationServices
import Foundation

final class DoubleControlHotkeyAgent {
  private let apiBaseURL: URL
  private let mode: String
  private let titlePrefix: String
  private let doubleTapThreshold: TimeInterval
  private let maxPressDuration: TimeInterval
  private let cooldown: TimeInterval

  private var lastFlags: NSEvent.ModifierFlags = []
  private var controlDownAt: Date?
  private var lastControlTapAt: Date?
  private var lastTriggerAt: Date?

  init(
    apiBaseURL: URL,
    mode: String,
    titlePrefix: String,
    doubleTapThreshold: TimeInterval = 0.38,
    maxPressDuration: TimeInterval = 0.25,
    cooldown: TimeInterval = 1.2
  ) {
    self.apiBaseURL = apiBaseURL
    self.mode = mode
    self.titlePrefix = titlePrefix
    self.doubleTapThreshold = doubleTapThreshold
    self.maxPressDuration = maxPressDuration
    self.cooldown = cooldown
  }

  func start() {
    requestAccessibilityAccessIfNeeded()

    NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.handle(event: event)
    }

    print("WalleBrain hotkey agent is running.")
    print("Listening for double Control. API base: \(apiBaseURL.absoluteString)")
    RunLoop.current.run()
  }

  func triggerOnceAndExit() {
    triggerWalleBrain(exitAfterCompletion: true)
    RunLoop.current.run()
  }

  private func requestAccessibilityAccessIfNeeded() {
    let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  private func handle(event: NSEvent) {
    let currentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let controlIsDown = currentFlags.contains(.control)
    let controlWasDown = lastFlags.contains(.control)
    let otherModifiers = currentFlags.subtracting([.control, .capsLock, .function])

    defer {
      lastFlags = currentFlags
    }

    if controlIsDown && !controlWasDown && otherModifiers.isEmpty {
      controlDownAt = Date()
      return
    }

    if !controlIsDown && controlWasDown {
      guard otherModifiers.isEmpty else {
        controlDownAt = nil
        return
      }

      let now = Date()
      let pressDuration = now.timeIntervalSince(controlDownAt ?? now)
      controlDownAt = nil

      guard pressDuration <= maxPressDuration else {
        lastControlTapAt = nil
        return
      }

      if let lastTriggerAt, now.timeIntervalSince(lastTriggerAt) < cooldown {
        return
      }

      if let lastTap = lastControlTapAt, now.timeIntervalSince(lastTap) <= doubleTapThreshold {
        lastControlTapAt = nil
        lastTriggerAt = now
        triggerWalleBrain(exitAfterCompletion: false)
      } else {
        lastControlTapAt = now
      }
    }
  }

  private func triggerWalleBrain(exitAfterCompletion: Bool) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm:ss"

    let title = "\(titlePrefix) \(formatter.string(from: Date()))"
    let endpoint = apiBaseURL.appending(path: "api/session/start-live")

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let payload: [String: Any] = [
      "title": title,
      "mode": mode,
      "processor": "auto",
      "dictationEnabled": true
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    } catch {
      fputs("Failed to encode hotkey payload: \(error)\n", stderr)
      return
    }

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      defer {
        if exitAfterCompletion {
          CFRunLoopStop(CFRunLoopGetMain())
        }
      }

      if let error {
        fputs("Hotkey trigger failed: \(error.localizedDescription)\n", stderr)
        return
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        fputs("Hotkey trigger failed: no HTTP response.\n", stderr)
        return
      }

      if httpResponse.statusCode == 409 {
        print("Live session already recording; ignoring hotkey trigger.")
        return
      }

      guard (200..<300).contains(httpResponse.statusCode) else {
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        fputs("Hotkey trigger failed with status \(httpResponse.statusCode): \(body)\n", stderr)
        return
      }

      print("Started WalleBrain live session from double Control.")
    }

    task.resume()
  }
}

let apiBase = ProcessInfo.processInfo.environment["WALLEBRAIN_API_BASE"] ?? "http://127.0.0.1:4173/"
let mode = ProcessInfo.processInfo.environment["WALLEBRAIN_HOTKEY_MODE"] ?? "normal"
let titlePrefix = ProcessInfo.processInfo.environment["WALLEBRAIN_TITLE_PREFIX"] ?? "会议记录"
let runOnce = ProcessInfo.processInfo.arguments.contains("--once")

guard let apiBaseURL = URL(string: apiBase.hasSuffix("/") ? apiBase : "\(apiBase)/") else {
  fputs("Invalid WALLEBRAIN_API_BASE: \(apiBase)\n", stderr)
  exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let agent = DoubleControlHotkeyAgent(
  apiBaseURL: apiBaseURL,
  mode: mode,
  titlePrefix: titlePrefix
)

if runOnce {
  agent.triggerOnceAndExit()
} else {
  agent.start()
}
