import AVFoundation
import CoreGraphics
import Foundation

public enum AudioInputCatalog {
  public static let mixedInputPrefix = "mixed-audio:"
  public static let systemAudioInputID = "system-audio:main-display"

  public static func availableInputs() -> [AudioInputDevice] {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external],
      mediaType: .audio,
      position: .unspecified
    )

    let hardwareInputs = discovery.devices.map {
      AudioInputDevice(id: $0.uniqueID, name: $0.localizedName)
    }

    let mixedInputs = hardwareInputs.map(makeMixedInput(for:))
    return mixedInputs + [AudioInputDevice(id: systemAudioInputID, name: "System Audio")] + hardwareInputs
  }

  public static func preferredInput(from devices: [AudioInputDevice]) -> AudioInputDevice? {
    let mixedInputs = devices.filter { isMixedInput(id: $0.id) }
    let hardwareInputs = devices.filter { !isSystemAudioInput(id: $0.id) && !isMixedInput(id: $0.id) }

    if let preferredMixed = mixedInputs.first(where: { isPreferredBuiltInMicrophoneName($0.name) }) {
      return preferredMixed
    }
    if let firstMixed = mixedInputs.first(where: { !isDeprioritizedExternalMicrophoneName($0.name) }) {
      return firstMixed
    }
    if let preferredHardware = hardwareInputs.first(where: { isPreferredBuiltInMicrophoneName($0.name) }) {
      return preferredHardware
    }

    return hardwareInputs.first(where: { !isDeprioritizedExternalMicrophoneName($0.name) }) ?? hardwareInputs.first
  }

  static func device(for id: String) -> AVCaptureDevice? {
    guard !isSystemAudioInput(id: id), !isMixedInput(id: id) else {
      return nil
    }

    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external],
      mediaType: .audio,
      position: .unspecified
    )
    return discovery.devices.first(where: { $0.uniqueID == id })
  }

  public static func isSystemAudioInput(id: String) -> Bool {
    id == systemAudioInputID
  }

  public static func isMixedInput(id: String) -> Bool {
    id.hasPrefix(mixedInputPrefix)
  }

  public static func makeMixedInput(for hardwareInput: AudioInputDevice) -> AudioInputDevice {
    AudioInputDevice(
      id: mixedInputPrefix + hardwareInput.id,
      name: "\(hardwareInput.name) + System Audio"
    )
  }

  public static func microphoneID(forMixedInput id: String) -> String? {
    guard isMixedInput(id: id) else {
      return nil
    }

    return String(id.dropFirst(mixedInputPrefix.count))
  }

  static func displayID(forSystemAudioInput id: String) -> CGDirectDisplayID? {
    guard id == systemAudioInputID || isMixedInput(id: id) else {
      return nil
    }

    return CGMainDisplayID()
  }

  private static func isPreferredBuiltInMicrophoneName(_ name: String) -> Bool {
    let lowercased = name.lowercased()
    return name.contains("MacBook Pro麦克风")
      || (lowercased.contains("macbook pro") && lowercased.contains("microphone"))
      || name.contains("MacBook Air麦克风")
      || (lowercased.contains("macbook air") && lowercased.contains("microphone"))
      || name.contains("内建麦克风")
      || lowercased.contains("built-in microphone")
  }

  private static func isDeprioritizedExternalMicrophoneName(_ name: String) -> Bool {
    let lowercased = name.lowercased()
    return name.contains("“")
      || name.contains("”")
      || name.contains("的麦克风")
      || lowercased.contains("iphone")
      || lowercased.contains("continuity")
      || lowercased.contains("桌上视角")
  }
}
