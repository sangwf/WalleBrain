// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "WalleBrainNative",
  platforms: [
    .macOS(.v26),
  ],
  products: [
    .library(
      name: "WalleBrainCore",
      targets: ["WalleBrainCore"]
    ),
    .executable(
      name: "WalleBrainApp",
      targets: ["WalleBrainApp"]
    ),
    .executable(
      name: "WalleBrainSpeechProbe",
      targets: ["WalleBrainSpeechProbe"]
    ),
    .executable(
      name: "WalleBrainAcceptance",
      targets: ["WalleBrainAcceptance"]
    ),
    .executable(
      name: "WalleBrainRealMeetingSmoke",
      targets: ["WalleBrainRealMeetingSmoke"]
    ),
  ],
  targets: [
    .target(
      name: "WalleBrainCore"
    ),
    .executableTarget(
      name: "WalleBrainApp",
      dependencies: ["WalleBrainCore"]
    ),
    .executableTarget(
      name: "WalleBrainSpeechProbe",
      dependencies: ["WalleBrainCore"]
    ),
    .executableTarget(
      name: "WalleBrainAcceptance",
      dependencies: ["WalleBrainCore"]
    ),
    .executableTarget(
      name: "WalleBrainRealMeetingSmoke",
      dependencies: ["WalleBrainCore"]
    ),
    .testTarget(
      name: "WalleBrainCoreTests",
      dependencies: ["WalleBrainCore"]
    ),
  ]
)
