import AVFoundation
import CoreGraphics
import Foundation
import Speech

public actor PermissionCoordinator {
  public init() {}

  public func requestMicrophoneAccess() async -> Bool {
    let currentStatus = await MainActor.run {
      AVCaptureDevice.authorizationStatus(for: .audio)
    }

    switch currentStatus {
    case .authorized:
      return true
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        Task { @MainActor in
          AVCaptureDevice.requestAccess(for: .audio) { granted in
            continuation.resume(returning: granted)
          }
        }
      }
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  public func requestSpeechAccess() async -> SFSpeechRecognizerAuthorizationStatus {
    let current = await MainActor.run {
      SFSpeechRecognizer.authorizationStatus()
    }
    if current != .notDetermined {
      return current
    }

    return await withCheckedContinuation { continuation in
      Task { @MainActor in
        SFSpeechRecognizer.requestAuthorization { status in
          continuation.resume(returning: status)
        }
      }
    }
  }

  public func requestScreenCaptureAccess() async -> Bool {
    await MainActor.run {
      if CGPreflightScreenCaptureAccess() {
        return true
      }

      return CGRequestScreenCaptureAccess()
    }
  }

  public func hasScreenCaptureAccess() async -> Bool {
    await MainActor.run {
      CGPreflightScreenCaptureAccess()
    }
  }
}
