import AppKit
import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct DecisionCardColumns {
  static let callouts = [
    Callout(kind: .warning, title: "CI is red", body: "The lint job fails."),
    Callout(kind: .info, title: "Reviewed by Copilot"),
    Callout(kind: .decision, title: "Fix items 3 and 5 first?", body: "Both touch the parser."),
  ]

  @Test(
    arguments: [
      ("Two review items are open.", callouts, true),
      ("Two review items are open.", [], false),
      ("", callouts, false),
      ("", [], false),
    ] as [(String, [Callout], Bool)])
  func onlyASummaryWithCalloutsSplits(summary: String, callouts: [Callout], splits: Bool) {
    let layout = DecisionCard.summaryLayout(summary: summary, callouts: callouts, listOpen: false)

    #expect((layout == .columns) == splits)
  }

  @Test func aWidePaneSplits55To45() throws {
    let columns = try #require(SummaryCalloutColumns.widths(for: 916))

    #expect(abs(columns.summary - 495) < 0.001)
    #expect(abs(columns.callouts - 405) < 0.001)
  }

  @Test func theThresholdGivesTheCalloutsTheMinimumColumn() throws {
    let threshold =
      SummaryCalloutColumns.minimumColumn / (1 - SummaryCalloutColumns.summaryShare)
      + SummaryCalloutColumns.spacing
    let columns = try #require(SummaryCalloutColumns.widths(for: threshold))

    #expect(abs(columns.callouts - 260) < 0.001)
    #expect(SummaryCalloutColumns.widths(for: threshold - 1) == nil)
  }

  /// The Inbox detail pane's minimum width is 340 pt, less 32 pt of padding.
  @Test func aNarrowPaneStacks() {
    #expect(SummaryCalloutColumns.widths(for: 308) == nil)
  }
}

@Suite struct SnapshotSize {
  @Test func readsWidthByHeight() {
    #expect(Snapshot.contentSize("900x700") == NSSize(width: 900, height: 700))
  }

  @Test(arguments: ["900", "0x700", "900x700xabc", "wide x tall"])
  func refusesAnythingElse(_ text: String) {
    #expect(Snapshot.contentSize(text) == nil)
  }
}
