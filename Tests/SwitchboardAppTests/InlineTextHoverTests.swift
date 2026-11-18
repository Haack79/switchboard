import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// `TextRenderer` exists from macOS 15. CI runs on macOS 26, so these rows skip only on an older local Mac.
private let hasRenderer = ProcessInfo.processInfo.isOperatingSystemAtLeast(
  OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))

private let width: CGFloat = 300
private let twoReferences = "See o/r#1 and o/r#2 next."

/// A Markdown link to an issue whose text wraps at a narrow width. The link run is one reference piece.
private let wrapping = MarkdownText([
  MarkdownText.Run("See "),
  MarkdownText.Run("the issue that tracks the slow hover card", link: "https://github.com/o/r/issues/1"),
  MarkdownText.Run(" today."),
])

/// A view in a window that is never shown, drawn once into a bitmap. The renderer records rects only while SwiftUI
/// draws, and `layoutSubtreeIfNeeded` on an unshown window does not draw.
@MainActor
private struct DrawnText {
  let window: NSWindow
  let rects = ReferenceRects()
  /// The size of the frame that holds the text: `width` wide and as tall as the text.
  let bounds: CGRect

  init<V: View>(_ view: V, model: BoardModel, width: CGFloat = width) {
    _ = NSApplication.shared
    let root = view.environment(\.referenceRects, rects).inlineLinks(model)
      .frame(width: width, alignment: .topLeading)
      .fixedSize(horizontal: false, vertical: true)
    let host = NSHostingView(rootView: root)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    bounds = CGRect(origin: .zero, size: host.fittingSize)
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
      host.cacheDisplay(in: host.bounds, to: bitmap)
    } else {
      Issue.record("The hosting view gave no bitmap to draw into.")
    }
  }

  var entries: [ReferenceRects.Entry] { rects.entries }

  /// Waits for the draw's records. The renderer may record on the next turn of the main run loop.
  func recorded() async -> [ReferenceRects.Entry] {
    await settle { !rects.entries.isEmpty }
    return entries
  }
}

/// Whether each entry follows the one before it in reading order: on a later line, or further right on the same line.
private func inReadingOrder(_ entries: [ReferenceRects.Entry]) -> Bool {
  zip(entries, entries.dropFirst()).allSatisfy { a, b in
    let sameLine = abs(b.rect.midY - a.rect.midY) < 1
    let laterLine = b.rect.minY >= a.rect.midY
    return b.part >= a.part && (laterLine || (sameLine && b.rect.minX >= a.rect.maxX - 1))
  }
}

/// Every `ReferenceAnchorView` under `view`.
@MainActor
private func anchorViews(in view: NSView) -> [ReferenceAnchorView] {
  view.subviews.flatMap { ($0 as? ReferenceAnchorView).map { [$0] } ?? anchorViews(in: $0) }
}

/// Hosted proof that hover detection works in the real `Text`. Row (a) is the control: when it fails,
/// the harness is wrong, not the API, and the rows after it say nothing.
@MainActor
@Suite(.enabled(if: hasRenderer, "TextRenderer needs macOS 15"))
struct InlineTextHoverTests {
  let model = offlineModel()

  /// (a) The control: a plain, non-selectable `InlineText` records one rect per reference.
  @Test func aPlainTextRecordsOneRectPerReference() async {
    let drawn = DrawnText(InlineText(plain: twoReferences), model: model)

    let entries = await drawn.recorded()

    #expect(entries.map(\.key) == ["github:o/r#1", "github:o/r#2"])
  }

  /// `inlineLinks` gives the text the model's reference card. No rects are injected here, so the card alone turns on
  /// the hover path.
  @Test func inlineLinksGivesTheTextTheModelsReferenceCard() async throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: InlineText(plain: twoReferences).inlineLinks(model).frame(width: width))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()

    await settle { !anchorViews(in: host).isEmpty }

    let anchor = try #require(anchorViews(in: host).first)
    #expect(anchor.card === model.referenceCard)
    withExtendedLifetime(window) {}
  }

  /// (b) `MarkdownView` makes its text selectable. The renderer must still run.
  @Test func aSelectableTextRecordsOneRectPerReference() async {
    let drawn = DrawnText(InlineText(plain: twoReferences).textSelection(.enabled), model: model)

    let entries = await drawn.recorded()

    #expect(entries.map(\.key) == ["github:o/r#1", "github:o/r#2"])
  }

  /// (b) The same, with the selection set on a container, as `MarkdownView` sets it.
  @Test func aTextInASelectableContainerRecordsOneRectPerReference() async {
    let drawn = DrawnText(VStack { InlineText(plain: twoReferences) }.textSelection(.enabled), model: model)

    let entries = await drawn.recorded()

    #expect(entries.map(\.key) == ["github:o/r#1", "github:o/r#2"])
  }

  @Test(arguments: [false, true])
  func eachReferenceHasItsOwnPart(selectable: Bool) async {
    let text = InlineText(plain: twoReferences)
    let drawn = DrawnText(selectable ? AnyView(text.textSelection(.enabled)) : AnyView(text), model: model)

    let entries = await drawn.recorded()

    #expect(Set(entries.map(\.part)).count == 2)
  }

  /// (c) Each rect lies inside the text's frame. A typographic bound can overhang by a fraction of a point.
  @Test(arguments: [false, true])
  func eachRectLiesInsideTheText(selectable: Bool) async {
    let text = InlineText(plain: twoReferences)
    let drawn = DrawnText(selectable ? AnyView(text.textSelection(.enabled)) : AnyView(text), model: model)

    let entries = await drawn.recorded()

    #expect(!entries.isEmpty)
    #expect(entries.allSatisfy { drawn.bounds.insetBy(dx: -1, dy: -1).contains($0.rect) })
  }

  @Test(arguments: [false, true])
  func eachRectHasSize(selectable: Bool) async {
    let text = InlineText(plain: twoReferences)
    let drawn = DrawnText(selectable ? AnyView(text.textSelection(.enabled)) : AnyView(text), model: model)

    let entries = await drawn.recorded()

    #expect(!entries.isEmpty)
    #expect(entries.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 })
  }

  /// (c) Rects come in text order, so the second reference's rect is right of the first's on one line.
  @Test(arguments: [false, true])
  func rectsComeInTextOrder(selectable: Bool) async {
    let text = InlineText(plain: twoReferences)
    let drawn = DrawnText(selectable ? AnyView(text.textSelection(.enabled)) : AnyView(text), model: model)

    let entries = await drawn.recorded()

    #expect(entries.count == 2)
    #expect(inReadingOrder(entries))
  }

  /// (d) A reference that wraps has a rect on each line, all for the one piece.
  @Test(arguments: [false, true])
  func aWrappedReferenceRecordsARectOnEachLine(selectable: Bool) async {
    let text = InlineText(wrapping)
    let drawn = DrawnText(
      selectable ? AnyView(text.textSelection(.enabled)) : AnyView(text), model: model, width: 140)

    let entries = await drawn.recorded()

    #expect(entries.count >= 2)
    #expect(Set(entries.map(\.key)) == ["github:o/r#1"])
    #expect(Set(entries.map(\.part)).count == 1)
    #expect(Set(entries.map { $0.rect.minY.rounded() }).count == entries.count)
  }

  /// The rects come from a twin behind selectable text. A twin that broke a line where the text does not would
  /// lose a reference to truncation or place it outside the text. A reference can wrap at its `/`, and then it
  /// records a rect on each line.
  @Test(arguments: stride(from: 120, through: 320, by: 9).map { CGFloat($0) })
  func aSelectableTextRecordsEachReferenceInsideItAtAnyWidth(width: CGFloat) async {
    let text = InlineText(plain: "Fix the card that sits below o/r#12 when the window is narrow, then o/r#34.")
    let drawn = DrawnText(text.textSelection(.enabled), model: model, width: width)

    let entries = await drawn.recorded()

    let firsts = entries.indices.filter { $0 == 0 || entries[$0 - 1].part != entries[$0].part }
    #expect(firsts.map { entries[$0].key } == ["github:o/r#12", "github:o/r#34"])
    #expect(entries.allSatisfy { drawn.bounds.insetBy(dx: -1, dy: -1).contains($0.rect) })
  }

  /// A caller can cut the text to one line. A rect outside what the line shows would open a card on nothing.
  @Test(arguments: [false, true])
  func aTextCutToOneLineRecordsRectsInsideIt(selectable: Bool) async {
    let text = InlineText(plain: "See o/r#1 and then a long tail of words that runs past the line, then o/r#2.")
      .lineLimit(1).truncationMode(.tail)
    let drawn = DrawnText(selectable ? AnyView(text.textSelection(.enabled)) : AnyView(text), model: model)

    let entries = await drawn.recorded()

    #expect(entries.first?.key == "github:o/r#1")
    #expect(entries.allSatisfy { drawn.bounds.insetBy(dx: -1, dy: -1).contains($0.rect) })
  }

  @Test func aWrappedReferencesRectsComeInTextOrder() async {
    let drawn = DrawnText(InlineText(wrapping), model: model, width: 140)

    let entries = await drawn.recorded()

    #expect(entries.count >= 2)
    #expect(inReadingOrder(entries))
  }

  /// A bare `#1` refers to the view's session repository. Its key names that repository.
  @Test func aBareNumberRecordsItsResolvedKey() async {
    let drawn = DrawnText(InlineText(plain: "Fix #1 first.").environment(\.referenceRepo, "o/r"), model: model)

    let entries = await drawn.recorded()

    #expect(entries.map(\.key) == ["github:o/r#1"])
  }

  // MARK: Guards: text with no hover target records nothing.

  /// Draws `view` beside a control that records, and returns what `view` recorded once the control has.
  private func recordedBeside<V: View>(_ view: V) async -> [ReferenceRects.Entry] {
    let control = DrawnText(InlineText(plain: twoReferences), model: model)
    let drawn = DrawnText(view, model: model)
    let controlEntries = await control.recorded()
    #expect(!controlEntries.isEmpty, "The control recorded nothing, so the harness is wrong.")
    try? await Task.sleep(nanoseconds: 200_000_000)
    return drawn.entries
  }

  /// `links: false` sits in a button's label, where the tile has its own hover card.
  @Test func aTextWithoutLinksRecordsNothing() async {
    #expect(await recordedBeside(InlineText(plain: twoReferences, links: false)).isEmpty)
  }

  @Test func aReferenceInACodeSpanRecordsNothing() async {
    let code = MarkdownText([MarkdownText.Run("See "), MarkdownText.Run("#1", .code)])

    #expect(await recordedBeside(InlineText(code).environment(\.referenceRepo, "o/r")).isEmpty)
  }

  @Test func aBareNumberWithoutARepositoryRecordsNothing() async {
    #expect(await recordedBeside(InlineText(plain: "Fix #1 first.")).isEmpty)
  }

  @Test func aLinkToAnotherSiteRecordsNothing() async {
    let text = MarkdownText([MarkdownText.Run("See "), MarkdownText.Run("docs", link: "https://example.com/docs")])

    #expect(await recordedBeside(InlineText(text)).isEmpty)
  }
}

/// Tagging each reference for the renderer must keep its link. These rows count and read the `AXLink`s and
/// never press one, because pressing a `Text` link crashes the test process.
@MainActor
@Suite struct InlineTextHoverLinkTests {
  let model = offlineModel()

  private func links<V: View>(_ view: V) -> [String] {
    HostedView(view.inlineLinks(model)).elements.filter { $0.role == "AXLink" }.map(\.label)
  }

  @Test func eachReferenceStillExposesALink() {
    #expect(links(InlineText(plain: twoReferences)) == ["o/r#1", "o/r#2"])
  }

  @Test func eachReferenceInASelectableTextStillExposesALink() {
    #expect(links(InlineText(plain: twoReferences).textSelection(.enabled)) == ["o/r#1", "o/r#2"])
  }

  @Test func aWrappedReferenceStillExposesOneLink() {
    #expect(links(InlineText(wrapping).frame(width: 140)).count == 1)
  }

  @Test func anotherLinkBesideAReferenceKeepsItsLink() {
    let text = MarkdownText([
      MarkdownText.Run("docs", link: "https://example.com/docs"), MarkdownText.Run(" and o/r#1"),
    ])

    #expect(links(InlineText(text)) == ["docs", "o/r#1"])
  }
}

// MARK: - Session links

private let liveID = "seb4ec"
private let liveName = "zsh-startup-for-switchboard"
private let removedID = "sgcctv"
private let removedName = "old-flag-cleanup"
private let idURL = "switchboard://session/\(liveID)"
private let otherID = "s3k9ap"
private let otherName = "flag-cache-race"

/// A model that lists one session, so its `sessionNames` resolve `liveID`.
@MainActor
private func namedModel() -> BoardModel {
  var s = needsItem(liveID)
  s.name = liveName
  return appliedModel([s])
}

/// The help of each accessibility element under the hosted view.
@MainActor
private func helps<V: View>(_ view: V) -> [String] {
  let hosted = HostedView(view.frame(width: width))
  // A key that the object does not answer would raise an exception and end the test process.
  return hosted.elements.map(\.object).filter {
    $0.responds(to: NSSelectorFromString("accessibilityHelp"))
  }
  .compactMap { $0.value(forKey: "accessibilityHelp") as? String }.filter { !$0.isEmpty }
}

extension InlineTextHoverTests {
  /// Every session link records a rect under a `session:` key, so the reference card opens on it.
  @MainActor
  @Suite struct SessionRects {
    @Test func aSessionNameRecordsItsSessionKey() async {
      let drawn = DrawnText(InlineText(plain: "Ask \(liveID) to rebase."), model: namedModel())

      let entries = await drawn.recorded()

      #expect(entries.map(\.key) == ["session:\(liveID)"])
    }

    @Test func aSessionNameRecordsASessionReferent() async {
      let drawn = DrawnText(InlineText(plain: "Ask \(liveID) to rebase."), model: namedModel())

      let entries = await drawn.recorded()

      #expect(entries.map(\.referent) == [.session(.id(liveID))])
    }

    @Test func aMarkdownSessionLinkRecordsItsSessionKey() async {
      let text = MarkdownText([MarkdownText.Run("Ask "), MarkdownText.Run("x", link: idURL)])
      let drawn = DrawnText(InlineText(text), model: offlineModel())

      let entries = await drawn.recorded()

      #expect(entries.map(\.key) == ["session:\(liveID)"])
    }

    /// A session link whose label is a code span or a footnote records a session referent, so the card opens on it.
    @Test(arguments: [MarkdownText.Run("fix-cache", .code, link: idURL), MarkdownText.Run("1", .footnote, link: idURL)])
    func aCodeOrFootnoteSessionLinkRecordsASessionReferent(_ run: MarkdownText.Run) async {
      let drawn = DrawnText(InlineText(MarkdownText([MarkdownText.Run("Ask "), run])), model: offlineModel())

      let entries = await drawn.recorded()

      #expect(entries.map(\.referent) == [.session(.id(liveID))])
    }

    @Test(arguments: [false, true])
    func aBareSessionURLRecordsItsSessionKey(selectable: Bool) async {
      let text = InlineText(plain: "See \(idURL) now.")
      let drawn = DrawnText(
        selectable ? AnyView(text.textSelection(.enabled)) : AnyView(text), model: offlineModel(), width: 400)

      let entries = await drawn.recorded()

      #expect(Set(entries.map(\.key)) == ["session:\(liveID)"])
    }

    @Test func aBracketLinkRecordsItsSessionKey() async {
      let drawn = DrawnText(InlineText(plain: "Ask [x](\(idURL)) now."), model: offlineModel())

      let entries = await drawn.recorded()

      #expect(entries.map(\.key) == ["session:\(liveID)"])
    }

    @Test func aNameURLRecordsItsNameKey() async {
      let drawn = DrawnText(InlineText(plain: "See switchboard://session/fix-cache now."), model: offlineModel())

      let entries = await drawn.recorded()

      #expect(entries.map(\.key) == ["session:fix-cache"])
    }

    @Test func aReferenceAndASessionLinkRecordInTextOrder() async {
      let drawn = DrawnText(InlineText(plain: "See o/r#1 and [x](\(idURL))."), model: offlineModel())

      let entries = await drawn.recorded()

      #expect(entries.map(\.key) == ["github:o/r#1", "session:\(liveID)"])
      #expect(inReadingOrder(entries))
    }

    // MARK: Guards

    /// Draws `view` beside a control that records, and returns what `view` recorded once the control has.
    private func recordedBeside<V: View>(_ view: V, model: BoardModel) async -> [ReferenceRects.Entry] {
      let control = DrawnText(InlineText(plain: twoReferences), model: model)
      let drawn = DrawnText(view, model: model)
      let controlEntries = await control.recorded()
      #expect(!controlEntries.isEmpty, "The control recorded nothing, so the harness is wrong.")
      try? await Task.sleep(nanoseconds: 200_000_000)
      return drawn.entries
    }

    @Test(arguments: ["Ask \(liveID) to rebase.", "See \(idURL) now.", "Ask [x](\(idURL)) now."])
    func aSessionLinkWithoutLinksRecordsNothing(_ s: String) async {
      #expect(await recordedBeside(InlineText(plain: s, links: false), model: namedModel()).isEmpty)
    }

    /// A removed session's name draws plain, with no link and no card.
    @Test func aRemovedSessionsNameRecordsNothing() async {
      let removed = SessionNames(live: [:], removed: [removedID: removedName])
      let text = InlineText(plain: "Ask \(removedID) to rebase.").environment(\.sessionNames, removed)

      #expect(await recordedBeside(text, model: offlineModel()).isEmpty)
    }

    @Test func aRefusedSessionURLRecordsNothing() async {
      #expect(await recordedBeside(InlineText(plain: "See \(idURL)?x=1 now."), model: offlineModel()).isEmpty)
    }

    // MARK: Links

    @Test func eachSessionLinkStillExposesALink() {
      let hosted = HostedView(
        InlineText(plain: "Ask \(liveID), [x](\(idURL)) and \(idURL).").inlineLinks(namedModel()).frame(width: 400))

      let links = hosted.elements.filter { $0.role == "AXLink" }.map(\.label)

      #expect(links == [liveName, "x", idURL])
    }
  }

  /// Decision 14: where the reference card can open on a session, the card shows the id, so the text drops its
  /// `name: id` help. Where no card can open, the help stays.
  @MainActor
  @Suite struct SessionHelp {
    /// The control: without a card, the help names the session, so the harness reads help.
    @Test func withoutACardTheHelpNamesTheSession() {
      let text = InlineText(plain: "Ask \(liveID) to rebase.")
        .environment(\.sessionNames, SessionNames(live: [liveID: liveName], removed: [:]))

      #expect(helps(text).contains("\(liveName): \(liveID)"))
    }

    /// The text beside it has no card, so its help shows that the walk reads help in this same view.
    @Test func withACardALiveSessionHasNoHelp() {
      let model = offlineModel()
      let names = SessionNames(live: [liveID: liveName, otherID: otherName], removed: [:])
      let view = VStack {
        InlineText(plain: "Ask \(liveID) to rebase.")
        InlineText(plain: "Ask \(otherID) to rebase.").environment(\.referenceCard, nil)
      }
      .environment(\.sessionNames, names)
      .environment(\.referenceCard, model.referenceCard)

      let found = helps(view)

      #expect(found.contains("\(otherName): \(otherID)"), "\(found)")
      #expect(!found.contains { $0.contains(liveID) }, "\(found)")
    }

    /// A removed session's name opens no card, so the card path does not draw the text and the help stays.
    @Test func withACardARemovedSessionKeepsItsHelp() {
      let model = offlineModel()
      let text = InlineText(plain: "Ask \(removedID) to rebase.")
        .environment(\.sessionNames, SessionNames(live: [:], removed: [removedID: removedName]))
        .environment(\.referenceCard, model.referenceCard)

      #expect(helps(text).contains("\(removedName): \(removedID), removed"))
    }

    /// A text inside a button's label draws no link and no card, and has no help today.
    @Test func withoutLinksThereIsStillNoHelp() {
      let found = helps(InlineText(plain: "Ask \(liveID) to rebase.", links: false).inlineLinks(namedModel()))

      #expect(!found.contains { $0.contains(liveID) }, "\(found)")
    }
  }
}
