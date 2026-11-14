import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let delay: TimeInterval = 0.5
private let grace: TimeInterval = 0.25

/// An action that `ManualScheduler` runs only when a test fires it.
private final class ScheduledAction {
  let interval: TimeInterval
  let action: @MainActor () -> Void
  var cancelled = false
  var fired = false
  var isPending: Bool { !cancelled && !fired }

  init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
    self.interval = interval
    self.action = action
  }
}

/// A scheduler whose actions run only when the test fires them.
@MainActor
private final class ManualScheduler {
  private var actions: [ScheduledAction] = []

  /// How many actions the controller has scheduled, fired or not.
  var count: Int { actions.count }

  func schedule(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
    let scheduled = ScheduledAction(interval: interval, action: action)
    actions.append(scheduled)
    return { scheduled.cancelled = true }
  }

  /// Runs each action that waits `interval` and is pending now, as if that much time passed.
  func fire(_ interval: TimeInterval) {
    for scheduled in actions where scheduled.interval == interval && scheduled.isPending {
      scheduled.fired = true
      scheduled.action()
    }
  }

  /// Runs every pending action, and each action that those actions schedule, in the order they were scheduled.
  func flush() {
    var runs = 0
    while runs < 100, let next = actions.first(where: \.isPending) {
      next.fired = true
      next.action()
      runs += 1
    }
  }
}

@MainActor
private final class RecordingPresenter<ID: Hashable & Sendable>: HoverCardPresenter {
  private(set) var shows: [(id: ID, anchor: HoverAnchor)] = []
  private(set) var hides = 0
  private(set) var refreshAnchors: [HoverAnchor] = []
  var refreshes: Int { refreshAnchors.count }

  func show(_ id: ID, below anchor: HoverAnchor) { shows.append((id, anchor)) }
  func hide() { hides += 1 }
  func refresh(below anchor: HoverAnchor) { refreshAnchors.append(anchor) }
}

private final class MouseButtons {
  var pressed = false
}

/// A hover card controller with a recording presenter, a manual scheduler, and tile anchors for A and B.
@MainActor
private final class CardFixture<ID: Hashable & Sendable> {
  let presenter: RecordingPresenter<ID>
  let scheduler: ManualScheduler
  let buttons: MouseButtons
  let card: HoverCard<ID>
  let a = HoverAnchor(view: NSView())
  let b = HoverAnchor(view: NSView())

  init() {
    let presenter = RecordingPresenter<ID>()
    let scheduler = ManualScheduler()
    let buttons = MouseButtons()
    self.presenter = presenter
    self.scheduler = scheduler
    self.buttons = buttons
    card = HoverCard<ID>(
      presenter: presenter, delay: delay, grace: grace, schedule: { scheduler.schedule($0, $1) },
      buttonsPressed: { buttons.pressed })
  }
}

/// The session card's fixture. Its ids are session ids.
private typealias Fixture = CardFixture<String>
/// The reference card's fixture.
private typealias ReferenceFixture = CardFixture<ReferenceCardID>

private func cardID(_ text: String) -> ReferenceCardID { ReferenceCardID(ref: GitHubRef(parsing: text)!) }

extension CardFixture where ID == String {
  /// Rests the pointer on tile A until its card shows.
  func openA() {
    card.entered("A", anchor: a)
    scheduler.fire(delay)
  }

  /// Whether A's card is open and has never closed, once every pending action has run.
  func aStaysOpen() -> Bool {
    scheduler.flush()
    return card.shown == "A" && presenter.hides == 0
  }
}

@MainActor
@Suite struct HoverCardTests {
  @MainActor
  @Suite struct Showing {
    @Test func restingOnATileShowsItsCardAfterTheDelay() {
      let f = Fixture()

      f.openA()

      #expect(f.card.shown == "A")
    }

    @Test func theCardShowsBelowTheTileUnderThePointer() {
      let f = Fixture()

      f.openA()

      #expect(f.presenter.shows.map { $0.id } == ["A"])
      #expect(f.presenter.shows.first?.anchor.view === f.a.view)
    }

    @Test func theCardDoesNotShowBeforeTheDelay() {
      let f = Fixture()

      f.card.entered("A", anchor: f.a)

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.isEmpty)
    }

    @Test func leavingTheTileBeforeTheDelayShowsNoCard() {
      let f = Fixture()
      f.card.entered("A", anchor: f.a)

      f.card.exited("A", anchor: f.a)
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.isEmpty)
    }

    @Test func theDefaultDelayIsHalfASecond() {
      let presenter = RecordingPresenter<String>()
      let scheduler = ManualScheduler()
      let card = HoverCard<String>(
        presenter: presenter, schedule: { scheduler.schedule($0, $1) }, buttonsPressed: { false })
      card.entered("A", anchor: HoverAnchor(view: NSView()))

      scheduler.fire(0.25)
      #expect(card.shown == nil)

      scheduler.fire(0.5)
      #expect(card.shown == "A")
    }
  }

  @MainActor
  @Suite struct Leaving {
    @Test func leavingTheTileKeepsTheCardOpenUntilTheGraceEnds() {
      let f = Fixture()
      f.openA()

      f.card.exited("A", anchor: f.a)

      #expect(f.card.shown == "A")
      #expect(f.presenter.hides == 0)
    }

    @Test func leavingTheTileHidesTheCardWhenTheGraceEnds() {
      let f = Fixture()
      f.openA()

      f.card.exited("A", anchor: f.a)
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }

    @Test func theDefaultGraceIsAQuarterSecond() {
      let presenter = RecordingPresenter<String>()
      let scheduler = ManualScheduler()
      let card = HoverCard<String>(
        presenter: presenter, schedule: { scheduler.schedule($0, $1) }, buttonsPressed: { false })
      let anchor = HoverAnchor(view: NSView())
      card.entered("A", anchor: anchor)
      scheduler.fire(0.5)

      card.exited("A", anchor: anchor)
      scheduler.fire(0.25)

      #expect(card.shown == nil)
    }

    @Test func movingOntoTheCardKeepsItOpen() {
      let f = Fixture()
      f.openA()

      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      #expect(f.aStaysOpen())
    }

    @Test func returningToTheTileWithinTheGraceKeepsTheCardOpen() {
      let f = Fixture()
      f.openA()

      f.card.exited("A", anchor: f.a)
      f.card.entered("A", anchor: f.a)

      #expect(f.aStaysOpen())
    }

    @Test func leavingTheCardKeepsItOpenUntilTheGraceEnds() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      f.card.exitedCard()

      #expect(f.card.shown == "A")
      #expect(f.presenter.hides == 0)
    }

    @Test func leavingTheCardHidesItWhenTheGraceEnds() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      f.card.exitedCard()
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }

    @Test func leavingTheCardForItsTileKeepsItOpen() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      f.card.exitedCard()
      f.card.entered("A", anchor: f.a)

      #expect(f.aStaysOpen())
    }

    @Test func leavingTheCardAndComingBackKeepsItOpen() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      f.card.exitedCard()
      f.card.enteredCard()

      #expect(f.aStaysOpen())
    }
  }

  @MainActor
  @Suite struct Interrupt {
    @Test func anInterruptHidesTheCardAtOnce() {
      let f = Fixture()
      f.openA()

      f.card.interrupt()

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }

    @Test func anInterruptCancelsAPendingCard() {
      let f = Fixture()
      f.card.entered("A", anchor: f.a)

      f.card.interrupt()
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.isEmpty)
    }

    @Test func theTileDoesNotShowItsCardAgainWhileThePointerStays() {
      let f = Fixture()
      f.openA()

      f.card.interrupt()
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.count == 1)
    }

    /// A click selects the session, and SwiftUI rebuilds the tile under the resting pointer.
    @Test func aTileRebuiltUnderThePointerAfterAnInterruptShowsNoCard() {
      let f = Fixture()
      f.openA()
      f.card.interrupt()

      f.card.disappeared(anchor: f.a)
      f.card.appeared("A", anchor: HoverAnchor(view: NSView()), pointerInside: true)
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.count == 1)
    }

    @Test func leavingAndReenteringTheTileAfterAnInterruptShowsTheCardAgain() {
      let f = Fixture()
      f.openA()
      f.card.interrupt()

      f.card.exited("A", anchor: f.a)
      f.card.entered("A", anchor: f.a)
      f.scheduler.fire(delay)

      #expect(f.card.shown == "A")
      #expect(f.presenter.shows.count == 2)
    }

    @Test func anInterruptDoesNotStopAnotherTileFromShowingItsCard() {
      let f = Fixture()
      f.openA()
      f.card.interrupt()

      f.card.exited("A", anchor: f.a)
      f.card.entered("B", anchor: f.b)
      f.scheduler.fire(delay)

      #expect(f.card.shown == "B")
    }
  }

  @MainActor
  @Suite struct Drag {
    @Test func enteringATileWithAButtonDownSchedulesNoCard() {
      let f = Fixture()
      f.buttons.pressed = true

      f.card.entered("A", anchor: f.a)

      #expect(f.scheduler.count == 0)
    }

    @Test func enteringATileWithAButtonDownShowsNoCard() {
      let f = Fixture()
      f.buttons.pressed = true

      f.card.entered("A", anchor: f.a)
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.isEmpty)
    }

    @Test func aTileThatAppearsUnderTheDragSchedulesNoCard() {
      let f = Fixture()
      f.buttons.pressed = true

      f.card.appeared("A", anchor: f.a, pointerInside: true)

      #expect(f.scheduler.count == 0)
    }

    @Test func enteringAgainAfterTheButtonComesUpShowsTheCard() {
      let f = Fixture()
      f.buttons.pressed = true
      f.card.entered("A", anchor: f.a)
      f.card.exited("A", anchor: f.a)
      f.buttons.pressed = false

      f.card.entered("A", anchor: f.a)
      f.scheduler.fire(delay)

      #expect(f.card.shown == "A")
    }
  }

  @MainActor
  @Suite struct Switching {
    /// Moves the pointer from tile A to tile B, reporting the exit first or the entry first.
    private func moveFromAToB(_ f: Fixture, exitFirst: Bool) {
      if exitFirst {
        f.card.exited("A", anchor: f.a)
        f.card.entered("B", anchor: f.b)
      } else {
        f.card.entered("B", anchor: f.b)
        f.card.exited("A", anchor: f.a)
      }
    }

    @Test(arguments: [true, false])
    func enteringAnotherTileKeepsTheOpenCardUntilTheDelayEnds(exitFirst: Bool) {
      let f = Fixture()
      f.openA()

      moveFromAToB(f, exitFirst: exitFirst)
      f.scheduler.fire(grace)

      #expect(f.card.shown == "A")
      #expect(f.presenter.shows.map { $0.id } == ["A"])
    }

    @Test(arguments: [true, false])
    func enteringAnotherTileSwitchesTheCardWhenTheDelayEnds(exitFirst: Bool) {
      let f = Fixture()
      f.openA()

      moveFromAToB(f, exitFirst: exitFirst)
      f.scheduler.fire(delay)

      #expect(f.card.shown == "B")
      #expect(f.presenter.shows.last?.id == "B")
      #expect(f.presenter.shows.last?.anchor.view === f.b.view)
    }

    /// The card can cover the tile below A, so the pointer crosses B on its way onto the card.
    @Test(arguments: [true, false])
    func enteringTheCardBeforeTheDelayCancelsTheSwitch(exitFirst: Bool) {
      let f = Fixture()
      f.openA()

      moveFromAToB(f, exitFirst: exitFirst)
      f.card.enteredCard()

      #expect(f.aStaysOpen())
      #expect(f.presenter.shows.map { $0.id } == ["A"])
    }

    @Test func aTileUnderTheCardDoesNotTakeTheCardWhileThePointerIsOnIt() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      f.card.entered("B", anchor: f.b)
      f.scheduler.flush()

      #expect(f.card.shown == "A")
      #expect(f.presenter.shows.map { $0.id } == ["A"])
    }

    @Test func leavingTheCardOntoAnotherTileSwitchesTheCardWhenTheDelayEnds() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()
      f.card.entered("B", anchor: f.b)

      f.card.exitedCard()
      #expect(f.card.shown == "A")
      f.scheduler.fire(delay)

      #expect(f.card.shown == "B")
      #expect(f.presenter.shows.last?.anchor.view === f.b.view)
    }
  }

  @MainActor
  @Suite struct SessionsChanged {
    @Test func aChangeThatStillShowsTheSessionKeepsItsCardOpen() {
      let f = Fixture()
      f.openA()

      f.card.sessionsChanged(shown: ["A", "B"])

      #expect(f.aStaysOpen())
    }

    @Test func aChangeThatStillShowsTheSessionRefreshesItsCard() {
      let f = Fixture()
      f.openA()

      f.card.sessionsChanged(shown: ["A", "B"])

      #expect(f.presenter.refreshes == 1)
    }

    @Test(arguments: [Set<String>(), ["B"]])
    func aChangeWithoutTheSessionHidesItsCard(_ shown: Set<String>) {
      let f = Fixture()
      f.openA()

      f.card.sessionsChanged(shown: shown)

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }
  }

  @MainActor
  @Suite struct Anchors {
    @Test func aTileRebuiltUnderThePointerKeepsTheCardOpen() {
      let f = Fixture()
      f.openA()

      f.card.disappeared(anchor: f.a)
      f.card.appeared("A", anchor: HoverAnchor(view: NSView()), pointerInside: true)

      #expect(f.aStaysOpen())
    }

    @Test func aTileRebuiltWhileThePointerIsOnTheCardKeepsTheCardOpen() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      f.card.disappeared(anchor: f.a)
      f.card.appeared("A", anchor: HoverAnchor(view: NSView()), pointerInside: false)

      #expect(f.aStaysOpen())
    }

    @Test func theTileLeavingTheWindowDoesNotHideTheCardAtOnce() {
      let f = Fixture()
      f.openA()

      f.card.disappeared(anchor: f.a)

      #expect(f.card.shown == "A")
      #expect(f.presenter.hides == 0)
    }

    @Test func theTileLeavingTheWindowWithNoNewTileHidesTheCardWhenTheGraceEnds() {
      let f = Fixture()
      f.openA()

      f.card.disappeared(anchor: f.a)
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }

    @Test func leavingARebuiltTileHidesTheCardWhenTheGraceEnds() {
      let f = Fixture()
      f.openA()
      let rebuilt = HoverAnchor(view: NSView())
      f.card.disappeared(anchor: f.a)
      f.card.appeared("A", anchor: rebuilt, pointerInside: true)

      f.card.exited("A", anchor: rebuilt)
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
    }

    @Test func anotherTileLeavingTheWindowKeepsTheCardOpen() {
      let f = Fixture()
      f.openA()

      f.card.disappeared(anchor: f.b)

      #expect(f.aStaysOpen())
    }

    /// The same session can show in the sidebar and on the Board at once.
    @Test func aSecondTileForTheSessionDoesNotTakeTheCardFromATileStillInItsWindow() {
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      defer { withExtendedLifetime(window) {} }
      let f = Fixture()
      window.contentView = f.a.view
      f.openA()
      let other = HoverAnchor(view: NSView())

      f.card.appeared("A", anchor: other, pointerInside: false)
      f.card.disappeared(anchor: other)

      #expect(f.aStaysOpen())
    }

    @Test func aTileRebuiltAfterTheGraceShowsTheCardAgainOnlyAfterTheDelay() {
      let f = Fixture()
      f.openA()
      f.card.disappeared(anchor: f.a)
      f.scheduler.fire(grace)
      let rebuilt = HoverAnchor(view: NSView())

      f.card.appeared("A", anchor: rebuilt, pointerInside: true)
      #expect(f.card.shown == nil)

      f.scheduler.fire(delay)
      #expect(f.card.shown == "A")
      #expect(f.presenter.shows.count == 2)
      #expect(f.presenter.shows.last?.anchor.view === rebuilt.view)
    }

    @Test func anotherSessionsTileInTheOldPlaceDoesNotTakeTheCard() {
      let f = Fixture()
      f.openA()

      f.card.disappeared(anchor: f.a)
      f.card.appeared("B", anchor: f.b, pointerInside: false)
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
    }

    @Test func aTileThatAppearsUnderThePointerShowsItsCardAfterTheDelay() {
      let f = Fixture()

      f.card.appeared("A", anchor: f.a, pointerInside: true)
      f.scheduler.fire(delay)

      #expect(f.card.shown == "A")
      #expect(f.presenter.shows.first?.anchor.view === f.a.view)
    }

    @Test func aTileThatLeavesTheWindowBeforeTheDelayShowsNoCard() {
      let f = Fixture()

      f.card.entered("A", anchor: f.a)
      f.card.disappeared(anchor: f.a)
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.isEmpty)
    }

    @Test func aTileThatLeavesTheWindowWhileAnotherCardIsOpenHidesThatCard() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.entered("B", anchor: f.b)

      f.card.disappeared(anchor: f.b)
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.map { $0.id } == ["A"])
    }

    @Test func aTileThatAppearsAwayFromThePointerShowsNoCard() {
      let f = Fixture()

      f.card.appeared("A", anchor: f.a, pointerInside: false)
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.isEmpty)
    }
  }

  /// One `InlineText` holds several references. Each reference is a part of the text's anchor view, and the rect
  /// that SwiftUI records for it changes on each draw.
  @MainActor
  @Suite struct References {
    private let first = "o/r#1"
    private let second = "o/r#2"
    private let text = NSView()
    private let rect = NSRect(x: 10, y: 4, width: 30, height: 14)
    private let moved = NSRect(x: 10, y: 22, width: 30, height: 14)

    private func part(_ index: Int, _ rect: NSRect? = nil) -> HoverAnchor {
      HoverAnchor(view: text, part: index, rect: rect)
    }

    /// Rests the pointer on `anchor` until its card shows.
    private func open(_ f: Fixture, _ id: String, _ anchor: HoverAnchor) {
      f.card.entered(id, anchor: anchor)
      f.scheduler.fire(delay)
    }

    /// Whether `id`'s card is open and has never closed, once every pending action has run.
    private func staysOpen(_ f: Fixture, _ id: String) -> Bool {
      f.scheduler.flush()
      return f.card.shown == id && f.presenter.hides == 0
    }

    /// The pointer reports the next reference before it reports leaving the last one. Only a comparison that
    /// reads `part` tells the late exit apart from an exit of the reference under the pointer.
    @Test func movingToAnotherReferenceInTheSameTextSwitchesTheCardWhenTheDelayEnds() {
      let f = Fixture()
      open(f, first, part(0, rect))

      f.card.entered(second, anchor: part(1, rect))
      f.card.exited(first, anchor: part(0, rect))
      f.scheduler.fire(delay)

      #expect(f.card.shown == second)
      #expect(f.presenter.shows.last?.anchor.part == 1)
    }

    @Test func aLateExitFromThePreviousReferenceDoesNotCloseTheCardWhenTheGraceEnds() {
      let f = Fixture()
      open(f, first, part(0, rect))

      f.card.entered(second, anchor: part(1, rect))
      f.card.exited(first, anchor: part(0, rect))
      f.scheduler.fire(grace)

      #expect(f.card.shown == first)
      #expect(f.presenter.hides == 0)
    }

    @Test func theSameReferenceTwiceInOneTextKeepsItsCardOpen() {
      let f = Fixture()
      open(f, first, part(0, rect))

      f.card.entered(first, anchor: part(1, moved))
      f.card.exited(first, anchor: part(0, rect))

      #expect(staysOpen(f, first))
      #expect(f.presenter.shows.count == 1)
    }

    @Test func theSameReferenceTwiceInOneTextMovesTheCardUnderTheSecond() {
      let f = Fixture()
      open(f, first, part(0, rect))

      f.card.entered(first, anchor: part(1, moved))
      f.card.exited(first, anchor: part(0, rect))
      f.scheduler.flush()

      #expect(f.presenter.refreshAnchors.last?.part == 1)
    }

    @Test func leavingTheSecondOccurrenceClosesTheCardWhenTheGraceEnds() {
      let f = Fixture()
      open(f, first, part(0, rect))
      f.card.entered(first, anchor: part(1, moved))
      f.card.exited(first, anchor: part(0, rect))

      f.card.exited(first, anchor: part(1, moved))
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
    }

    /// A chat redraws on each model update, and the renderer records the reference's rect again.
    @Test func aRedrawThatMovesTheRectKeepsTheCardOpen() {
      let f = Fixture()
      open(f, first, part(0, rect))

      f.card.entered(first, anchor: part(0, moved))

      #expect(staysOpen(f, first))
      #expect(f.presenter.shows.count == 1)
    }

    @Test func aRedrawThatMovesTheRectPlacesTheCardAtTheNewRect() {
      let f = Fixture()
      open(f, first, part(0, rect))

      f.card.entered(first, anchor: part(0, moved))

      #expect(f.presenter.refreshAnchors.last?.rect == moved)
    }

    /// The rect is placement data only. An exit whose rect differs from the enter's still leaves the reference.
    @Test func anExitWithTheSamePartAndAnotherRectClosesTheCardWhenTheGraceEnds() {
      let f = Fixture()
      open(f, first, part(0, rect))

      f.card.exited(first, anchor: part(0, moved))
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }

    @Test func anExitWithTheSamePartAndAnotherRectKeepsTheCardUntilTheGraceEnds() {
      let f = Fixture()
      open(f, first, part(0, rect))

      f.card.exited(first, anchor: part(0, moved))

      #expect(f.card.shown == first)
      #expect(f.presenter.hides == 0)
    }

    @Test func anExitFromAnotherViewWithTheSamePartDoesNotCloseTheCard() {
      let f = Fixture()
      open(f, first, part(0, rect))

      f.card.exited(first, anchor: HoverAnchor(view: NSView(), part: 0, rect: rect))

      #expect(staysOpen(f, first))
    }

    /// A tile's anchor covers the whole view. A reference's anchor is one part of it.
    @Test func aWholeViewAnchorAndAPartOfTheSameViewAreDifferentHovers() {
      let f = Fixture()
      open(f, first, HoverAnchor(view: text))

      f.card.entered(second, anchor: part(0, rect))
      f.card.exited(first, anchor: HoverAnchor(view: text))
      f.scheduler.fire(delay)

      #expect(f.card.shown == second)
    }

    @Test func theCardShowsBelowTheReferencesRect() {
      let f = Fixture()

      open(f, first, part(0, rect))

      #expect(f.presenter.shows.first?.anchor.view === text)
      #expect(f.presenter.shows.first?.anchor.rect == rect)
    }

    /// The text's anchor view reports leaving its window with no part. Every reference in it leaves with it.
    @Test func aTextThatLeavesItsWindowClosesTheCardOfOneOfItsReferencesWhenTheGraceEnds() {
      let f = Fixture()
      open(f, first, part(0, rect))

      f.card.disappeared(anchor: HoverAnchor(view: text))
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
    }

    @Test func aTextThatLeavesItsWindowCancelsThePendingCardOfOneOfItsReferences() {
      let f = Fixture()
      f.card.entered(first, anchor: part(0, rect))

      f.card.disappeared(anchor: HoverAnchor(view: text))
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.isEmpty)
    }
  }

  /// The reference card holds links, so a mouse down inside it must not close it before the link fires. The
  /// session card closes on any click.
  @MainActor
  @Suite struct Clicks {
    private func window() -> NSWindow {
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      return window
    }

    @Test func aMouseDownInTheReferenceCardsPanelKeepsTheCardOpen() {
      let f = Fixture()
      let panel = window()
      f.card.clickableWindow = panel
      f.openA()

      f.card.mouseDown(in: panel)

      #expect(f.aStaysOpen())
    }

    @Test func aMouseDownInAnotherWindowClosesTheReferenceCard() {
      let f = Fixture()
      let panel = window()
      let main = window()
      f.card.clickableWindow = panel
      f.openA()

      f.card.mouseDown(in: main)

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }

    @Test func aMouseDownInNoWindowClosesTheReferenceCard() {
      let f = Fixture()
      f.card.clickableWindow = window()
      f.openA()

      f.card.mouseDown(in: nil)

      #expect(f.card.shown == nil)
    }

    /// A scroll or a key closes the card even while the pointer is on it.
    @Test func anInterruptStillClosesTheReferenceCard() {
      let f = Fixture()
      f.card.clickableWindow = window()
      f.openA()

      f.card.interrupt()

      #expect(f.card.shown == nil)
    }

    @Test func theSessionCardClosesOnAMouseDownInItsOwnPanel() {
      let f = Fixture()
      let panel = window()
      f.openA()

      f.card.mouseDown(in: panel)

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }
  }

  /// `ReferenceHover` turns the pointer's moves over one text into the reference card's enters and exits.
  @MainActor
  @Suite struct Pointer {
    private let view = ReferenceAnchorView()
    private let hover = ReferenceHover()
    private let entries = [
      ReferenceRects.Entry(ref: GitHubRef(parsing: "o/r#1")!, part: 1, rect: CGRect(x: 0, y: 0, width: 40, height: 14)),
      ReferenceRects.Entry(
        ref: GitHubRef(parsing: "O/R#2")!, part: 3, rect: CGRect(x: 60, y: 0, width: 40, height: 14)),
    ]

    init() { hover.view = view }

    private func move(_ f: ReferenceFixture, _ x: CGFloat?, in entries: [ReferenceRects.Entry]? = nil) {
      hover.moved(to: x.map { CGPoint(x: $0, y: 7) }, in: entries ?? self.entries, card: f.card)
    }

    /// Each enter restarts the card's delay, so a pointer that kept moving on a reference would never open it.
    @Test func movingWithinOneReferenceStartsTheDelayOnce() {
      let f = ReferenceFixture()

      move(f, 5)
      move(f, 30)

      #expect(f.scheduler.count == 1)
    }

    @Test func restingOnAReferenceOpensItsCard() {
      let f = ReferenceFixture()

      move(f, 5)
      f.scheduler.fire(delay)

      #expect(f.card.shown?.ref.key == "o/r#1")
      #expect(f.presenter.shows.first?.anchor.part == 1)
    }

    /// The card shows the reference as the text wrote it.
    @Test func movingToAnotherReferenceOpensItsCardWhenTheDelayEnds() {
      let f = ReferenceFixture()
      move(f, 5)
      f.scheduler.fire(delay)

      move(f, 70)
      f.scheduler.fire(delay)

      #expect(f.card.shown?.ref.repo == "O/R")
      #expect(f.card.shown?.ref.number == 2)
    }

    /// The card's header links to the URL's kind of page, so the card keeps the form of the reference.
    @Test func aPullRequestURLOpensACardThatKeepsItsForm() {
      let f = ReferenceFixture()
      let pull = [
        ReferenceRects.Entry(
          ref: GitHubRef(parsing: "https://github.com/o/r/pull/9")!, part: 0,
          rect: CGRect(x: 0, y: 0, width: 40, height: 14))
      ]

      move(f, 5, in: pull)
      f.scheduler.fire(delay)

      #expect(f.card.shown?.ref.isPull == true)
    }

    /// Two references to one item, in another case or form, are one card, so moving between them keeps it open.
    @Test func movingToAnotherReferenceToTheSameItemKeepsTheCard() {
      let f = ReferenceFixture()
      let same = [
        ReferenceRects.Entry(
          ref: GitHubRef(parsing: "o/r#1")!, part: 0, rect: CGRect(x: 0, y: 0, width: 40, height: 14)),
        ReferenceRects.Entry(
          ref: GitHubRef(parsing: "https://github.com/O/R/pull/1")!, part: 1,
          rect: CGRect(x: 60, y: 0, width: 40, height: 14)),
      ]
      move(f, 5, in: same)
      f.scheduler.fire(delay)

      move(f, 70, in: same)
      f.scheduler.flush()

      #expect(f.presenter.shows.count == 1)
      #expect(f.presenter.hides == 0)
    }

    @Test func movingBetweenTheReferencesOpensNoCard() {
      let f = ReferenceFixture()
      move(f, 5)

      move(f, 50)
      f.scheduler.flush()

      #expect(f.card.shown == nil)
    }

    @Test func leavingTheTextClosesTheCardWhenTheGraceEnds() {
      let f = ReferenceFixture()
      move(f, 5)
      f.scheduler.fire(delay)

      move(f, nil)
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
    }

    /// A text that leaves its window while the pointer rests on a reference gets no exit. On its return, the same
    /// point must start the delay again.
    @Test func aTextThatReturnsToItsWindowOpensTheCardAgain() {
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      defer { withExtendedLifetime(window) {} }
      let f = ReferenceFixture()
      view.card = f.card
      view.hover = hover
      window.contentView = view
      move(f, 5)

      window.contentView = nil
      window.contentView = view
      move(f, 5)
      f.scheduler.fire(delay)

      #expect(f.card.shown?.ref.key == "o/r#1")
    }
  }
}

/// BoardModel tells its hover card which sessions it shows after each refresh and each org filter change.
@MainActor
@Suite struct HoverCardBoardModelTests {
  private func session(_ id: String, state: AttentionState = .working, reason: String = "") -> SessionSummary {
    var s = needsItem(id, state: state)
    s.reason = reason
    return s
  }

  /// A model that shows `list`, with its hover card open on A.
  private func openOnA(
    _ model: BoardModel, _ list: [SessionSummary], followups: [SessionSummary]? = nil
  ) -> Fixture {
    let f = Fixture()
    model.hoverCard = f.card
    model.apply(.success(list), followups: followups)
    f.openA()
    return f
  }

  @Test func anUpdateToAnotherSessionKeepsTheCardOpen() {
    let model = offlineModel()
    let f = openOnA(model, [session("A"), session("B")])

    model.apply(
      .success([session("A"), session("B", state: .needsYou, reason: "answer: which flag?")]), followups: nil)

    #expect(f.aStaysOpen())
  }

  @Test func aRebuiltTileThenAnUpdateToAnotherSessionKeepsTheCardOpen() {
    let model = offlineModel()
    let f = openOnA(model, [session("A"), session("B")])
    let rebuilt = HoverAnchor(view: NSView())
    f.card.disappeared(anchor: f.a)
    f.card.appeared("A", anchor: rebuilt, pointerInside: true)

    model.apply(
      .success([session("A"), session("B", state: .needsYou, reason: "answer: which flag?")]), followups: nil)

    #expect(f.aStaysOpen())
    #expect(f.presenter.refreshAnchors.last?.view === rebuilt.view)
  }

  @Test func anUpdateToTheSessionKeepsItsCardOpen() {
    let model = offlineModel()
    let f = openOnA(model, [session("A"), session("B")])

    model.apply(.success([session("A", state: .waiting, reason: "waits on CI"), session("B")]), followups: nil)

    #expect(f.aStaysOpen())
  }

  @Test func anUpdateToTheSessionRefreshesItsCard() {
    let model = offlineModel()
    let f = openOnA(model, [session("A"), session("B")])
    let before = f.presenter.refreshes

    model.apply(.success([session("A", state: .waiting, reason: "waits on CI"), session("B")]), followups: nil)

    #expect(f.presenter.refreshes > before)
  }

  @Test func anUpdateThatRemovesTheSessionHidesItsCard() {
    let model = offlineModel()
    let f = openOnA(model, [session("A"), session("B")])

    model.apply(.success([session("B")]), followups: nil)

    #expect(f.card.shown == nil)
    #expect(f.presenter.hides == 1)
  }

  @Test func anUpdateToAShownFollowupsNeighborKeepsTheFollowupsCardOpen() {
    let model = offlineModel()
    let f = Fixture()
    model.hoverCard = f.card
    model.apply(.success([session("B")]), followups: [unstartedFollowup("F", nil)])
    f.card.entered("F", anchor: f.a)
    f.scheduler.fire(delay)

    model.apply(.success([session("B", state: .needsYou, reason: "answer: which flag?")]), followups: nil)
    f.scheduler.flush()

    #expect(f.card.shown == "F")
    #expect(f.presenter.hides == 0)
  }

  /// The reference card is a second `HoverCard`. A session list change never closes it, because its id names no
  /// session.
  @Test func anUpdateLeavesAnOpenReferenceCardOpen() {
    let model = offlineModel()
    model.apply(.success([session("A"), session("B")]), followups: nil)
    let f = ReferenceFixture()
    model.referenceCard = f.card
    f.card.entered(cardID("o/r#1"), anchor: f.a)
    f.scheduler.fire(delay)

    model.apply(.success([session("B")]), followups: nil)
    f.scheduler.flush()

    #expect(f.card.shown == cardID("o/r#1"))
    #expect(f.presenter.hides == 0)
  }

  @Test func aFilterChangeLeavesAnOpenReferenceCardOpen() {
    let model = orgFilterModel(OrgFilter())
    model.apply(.success([orgSession("A", "haacked/switchboard")]), followups: nil)
    let f = ReferenceFixture()
    model.referenceCard = f.card
    f.card.entered(cardID("o/r#1"), anchor: f.a)
    f.scheduler.fire(delay)

    model.orgFilter = posthogOnly
    f.scheduler.flush()

    #expect(f.card.shown == cardID("o/r#1"))
    #expect(f.presenter.hides == 0)
  }

  @Test func aFilterChangeThatHidesTheSessionHidesItsCard() {
    let model = orgFilterModel(OrgFilter())
    let f = openOnA(model, [orgSession("A", "haacked/switchboard"), orgSession("B", "PostHog/posthog")])

    model.orgFilter = posthogOnly

    #expect(f.card.shown == nil)
    #expect(f.presenter.hides == 1)
  }

  @Test func aFilterChangeThatKeepsTheSessionKeepsItsCardOpen() {
    let model = orgFilterModel(OrgFilter())
    let f = openOnA(model, [orgSession("A", "PostHog/posthog"), orgSession("B", "haacked/switchboard")])

    model.orgFilter = posthogOnly

    #expect(f.aStaysOpen())
  }

  @Test func aFilterChangeThatKeepsTheSessionRefreshesItsCard() {
    let model = orgFilterModel(OrgFilter())
    let f = openOnA(model, [orgSession("A", "PostHog/posthog"), orgSession("B", "haacked/switchboard")])
    let before = f.presenter.refreshes

    model.orgFilter = posthogOnly

    #expect(f.presenter.refreshes > before)
  }

  @Test func aRefreshThatMovesTheSessionOutOfTheFilterHidesItsCard() {
    let model = orgFilterModel(posthogOnly)
    let f = openOnA(model, [orgSession("A", "PostHog/posthog"), orgSession("B", "PostHog/posthog-js")])

    model.apply(
      .success([orgSession("A", "haacked/switchboard"), orgSession("B", "PostHog/posthog-js")]), followups: nil)

    #expect(f.card.shown == nil)
    #expect(f.presenter.hides == 1)
  }
}
