import AppKit
import ApplicationServices
import Foundation

@MainActor
final class GlobalHotkeyController {
  private weak var model: AppModel?

  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var lastFlags: NSEvent.ModifierFlags = []
  private var leftCommandDownAt: Date?
  private var lastLeftCommandTapAt: Date?
  private var lastTriggerAt: Date?

  private let doubleTapThreshold: TimeInterval
  private let maxPressDuration: TimeInterval
  private let cooldown: TimeInterval

  init(
    doubleTapThreshold: TimeInterval = 0.38,
    maxPressDuration: TimeInterval = 0.25,
    cooldown: TimeInterval = 0.6
  ) {
    self.doubleTapThreshold = doubleTapThreshold
    self.maxPressDuration = maxPressDuration
    self.cooldown = cooldown
  }

  func bind(model: AppModel) {
    self.model = model
  }

  func startIfNeeded() {
    guard globalMonitor == nil, localMonitor == nil else {
      return
    }

    requestAccessibilityAccessIfNeeded()
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      Task { @MainActor in
        self?.handle(event: event)
      }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.handle(event: event)
      return event
    }
  }

  private func requestAccessibilityAccessIfNeeded() {
    guard !AXIsProcessTrusted() else {
      return
    }

    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  private func handle(event: NSEvent) {
    guard event.keyCode == 55 else {
      lastFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      return
    }

    let currentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let leftCommandIsDown = currentFlags.contains(.command)
    let leftCommandWasDown = lastFlags.contains(.command)
    let otherModifiers = currentFlags.subtracting([.command, .capsLock, .function])

    defer {
      lastFlags = currentFlags
    }

    if leftCommandIsDown && !leftCommandWasDown && otherModifiers.isEmpty {
      leftCommandDownAt = Date()
      return
    }

    if !leftCommandIsDown && leftCommandWasDown {
      guard otherModifiers.isEmpty else {
        leftCommandDownAt = nil
        return
      }

      let now = Date()
      let pressDuration = now.timeIntervalSince(leftCommandDownAt ?? now)
      leftCommandDownAt = nil

      guard pressDuration <= maxPressDuration else {
        lastLeftCommandTapAt = nil
        return
      }

      if let lastTriggerAt, now.timeIntervalSince(lastTriggerAt) < cooldown {
        return
      }

      if let lastTap = lastLeftCommandTapAt, now.timeIntervalSince(lastTap) <= doubleTapThreshold {
        lastLeftCommandTapAt = nil
        lastTriggerAt = now
        Task {
          await model?.toggleMeetingFromHotkey()
        }
      } else {
        lastLeftCommandTapAt = now
      }
    }
  }
}
