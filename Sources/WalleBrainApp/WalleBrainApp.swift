import SwiftUI

@main
struct WalleBrainApp: App {
  private let isSmokeMode = CommandLine.arguments.contains("--smoke-meeting")
  @StateObject private var model = AppModel()
  @State private var hotkeyController = GlobalHotkeyController()
  @State private var didBootstrap = false

  var body: some Scene {
    WindowGroup {
      Group {
        if isSmokeMode {
          SmokeRunnerView(model: model)
        } else {
          ContentView(model: model)
        }
      }
        .task {
          guard !didBootstrap else {
            return
          }

          didBootstrap = true
          await model.bootstrap()

          if !isSmokeMode {
            hotkeyController.bind(model: model)
            hotkeyController.startIfNeeded()
          }
        }
    }
  }
}
