import Foundation
import Testing
@testable import WalleBrainCore

struct AcceptanceHarnessTests {
  @Test
  func evaluatesStructuredFixtureSuite() throws {
    let baseDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let suite = try AcceptanceHarness.loadStructuredNoteFixtureSuite(baseDirectory: baseDirectory)

    let summary = try AcceptanceHarness.evaluateFixtureSuite(suite)

    #expect(summary.passed)
    #expect(summary.cases.count == 4)
  }

  @Test
  func performsTargetedReviewRoundTrip() {
    let result = AcceptanceHarness.reviewRoundTripCheck()

    #expect(result.passed)
    #expect(result.before != result.after)
  }

  @Test
  func decodesLegacySessionPayloadInHarness() throws {
    #expect(try AcceptanceHarness.decodeLegacySessionCheck())
  }

  @Test
  func reportsRequiredStructuredSections() {
    let note = """
    ## Summary
    x
    ## Organized Transcript
    x
    ## Key Points
    x
    ## Decisions
    x
    ## Action Items
    x
    ## Open Loops
    x
    ## Risks
    x
    ## Related Projects
    x
    ## Related People
    x
    ## Participant Positions
    x
    ## Live Transcript
    x
    ## Final Transcript
    x
    """

    let report = AcceptanceHarness.requiredStructuredSectionsPresent(in: note)
    #expect(report.values.allSatisfy { $0 })
  }

  @Test
  func retriesTransientFixtureFailuresBeforeSucceeding() async throws {
    actor AttemptCounter {
      var count = 0

      func next() -> Int {
        count += 1
        return count
      }
    }

    let counter = AttemptCounter()
    let value = try await AcceptanceHarness.retrying(attempts: 2, retryDelaySeconds: 0) {
      let attempt = await counter.next()
      if attempt == 1 {
        throw AcceptanceHarnessError.fixtureTimeout("transient")
      }
      return 42
    }

    #expect(value == 42)
  }

  @Test
  func deterministicFixturesFailWhenForbiddenDecisionAppears() throws {
    let fixture = StructuredNoteFixture(
      id: "decision-action-project",
      title: "Decision Not Allowed",
      transcript: "我们决定 Atlas 下周上线，这周内把发布 checklist 补齐。",
      expectations: StructuredNoteExpectations(
        decisionContains: [],
        actionItemContains: [],
        preserveTentativeTerms: [],
        forbidDecisions: true,
        forbidActionItems: false,
        projectStatusByID: [:]
      )
    )

    let suite = StructuredNoteFixtureSuite(fixtures: [fixture])
    let summary = try AcceptanceHarness.evaluateFixtureSuite(suite)

    #expect(summary.passed == false)
    #expect(summary.cases.first?.errors.contains("unexpected decisions present") == true)
  }
}
