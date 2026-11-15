import AppKit

/// What a hover card sits below: a whole view, or one part of it, such as one
/// reference in a text.
struct HoverAnchor: Equatable {
  let view: NSView
  /// Names one hover target inside `view`, or nil for the whole view.
  let part: Int?
  /// Where the part sits in `view`'s coordinates. Nil means the view's bounds.
  let rect: NSRect?

  init(view: NSView, part: Int? = nil, rect: NSRect? = nil) {
    self.view = view
    self.part = part
    self.rect = rect
  }

  /// Whether `other` names the same part of the same view. The rect is
  /// placement data only: SwiftUI records it again on each draw, so an enter
  /// and its exit can carry different rects.
  func isSameTarget(as other: HoverAnchor?) -> Bool { view === other?.view && part == other?.part }
}

/// Draws the hover card that `HoverCard` decides to show.
@MainActor
protocol HoverCardPresenter<ID>: AnyObject {
  associatedtype ID: Hashable & Sendable

  func show(_ id: ID, below anchor: HoverAnchor)
  func hide()
  /// Places the card again below `anchor`, after the anchor moved or its tile was rebuilt. The card places itself
  /// when its contents change size.
  func refresh(below anchor: HoverAnchor)
}

/// Decides when a hover target's card shows, for a session tile or a
/// reference in text. The card opens after the pointer rests on a target for
/// `delay`. It stays open while the pointer is on the target or on the card,
/// and closes `grace` after the pointer leaves both. For the session card, a
/// model update leaves the card open unless the session is no longer shown.
/// A rebuilt target replaces its anchor view. The new anchor keeps the card.
/// A mouse down closes the card, except one in `clickableWindow`.
@MainActor
final class HoverCard<ID: Hashable & Sendable> {
  typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

  private(set) var shown: ID?
  /// The window of a card whose links take clicks. A mouse down in it keeps the card open.
  weak var clickableWindow: NSWindow?
  private let presenter: any HoverCardPresenter<ID>
  private let delay: TimeInterval
  private let grace: TimeInterval
  private let schedule: Schedule
  private let buttonsPressed: () -> Bool

  private var hovered: (id: ID, anchor: HoverAnchor)?
  /// The anchor that the open card sits below.
  private var anchor: HoverAnchor?
  private var onCard = false
  /// A tile whose card a click or key closed. It shows again only after the pointer leaves it.
  private var suppressed: ID?
  private var cancelPending: (() -> Void)?

  init(
    presenter: any HoverCardPresenter<ID>, delay: TimeInterval = 0.5, grace: TimeInterval = 0.25,
    schedule: @escaping Schedule = HoverCard.timer,
    buttonsPressed: @escaping () -> Bool = { NSEvent.pressedMouseButtons != 0 }
  ) {
    self.presenter = presenter
    self.delay = delay
    self.grace = grace
    self.schedule = schedule
    self.buttonsPressed = buttonsPressed
  }

  static func timer(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
    let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
      MainActor.assumeIsolated { action() }
    }
    return { timer.invalidate() }
  }

  func entered(_ id: ID, anchor: HoverAnchor) {
    hovered = (id, anchor)
    // A tile under the card can report an enter while the pointer is on the card.
    if onCard, shown != nil, shown != id { return }
    if shown == id {
      adopt(anchor)
      cancel()
      return
    }
    // A drag to a group crosses other tiles with the button down.
    guard suppressed != id, !buttonsPressed() else { return }
    after(delay) { [weak self] in self?.open(id, below: anchor) }
  }

  func exited(_ id: ID, anchor: HoverAnchor) {
    guard anchor.isSameTarget(as: hovered?.anchor) else { return }
    hovered = nil
    if suppressed == id { suppressed = nil }
    if shown == nil { cancel() } else if !onCard { closeAfterGrace() }
  }

  /// A tile's anchor joined a window. SwiftUI replaces a tile's anchor when it
  /// rebuilds the tile. The new anchor gets no enter event while the pointer rests on it.
  func appeared(_ id: ID, anchor: HoverAnchor, pointerInside: Bool) {
    if shown == id, self.anchor?.view.window == nil {
      adopt(anchor)
      if pointerInside { hovered = (id, anchor) }
      if pointerInside || onCard { cancel() }
      return
    }
    if pointerInside { entered(id, anchor: anchor) }
  }

  /// `anchor`'s view left its window, and every part of the view left with it.
  func disappeared(anchor: HoverAnchor) {
    let wasHovered = hovered?.anchor.view === anchor.view
    if wasHovered { hovered = nil }
    guard wasHovered || anchor.view === self.anchor?.view else { return }
    // A pending open targets the hovered anchor, which can no longer show a card.
    if shown == nil { cancel() } else if !onCard { closeAfterGrace() }
  }

  func enteredCard() {
    onCard = true
    if shown != nil { cancel() }
  }

  func exitedCard() {
    onCard = false
    guard shown != nil else { return }
    if let tile = hovered {
      if tile.id != shown, suppressed != tile.id {
        after(delay) { [weak self] in self?.open(tile.id, below: tile.anchor) }
      }
    } else {
      closeAfterGrace()
    }
  }

  /// A mouse down in `window` closes the card unless `window` is `clickableWindow`.
  func mouseDown(in window: NSWindow?) {
    if let window, window === clickableWindow { return }
    interrupt()
  }

  /// A mouse down, a scroll, or a key closes the card at once, as it closes a native tooltip.
  func interrupt() {
    suppressed = hovered?.id
    cancel()
    close()
  }

  /// Closes the card when `ids` leaves its session out. Otherwise it places the card again, because the update can
  /// move the session's tile.
  func sessionsChanged(shown ids: Set<ID>) {
    guard let shown else { return }
    if !ids.contains(shown) {
      close()
    } else if let anchor {
      presenter.refresh(below: anchor)
    }
  }

  /// Shows the card for `id` without a pointer, for a snapshot.
  func pin(_ id: ID, below anchor: HoverAnchor) { open(id, below: anchor) }

  private func open(_ id: ID, below anchor: HoverAnchor) {
    cancel()
    shown = id
    self.anchor = anchor
    presenter.show(id, below: anchor)
  }

  /// Places the card below `anchor` when it is another target or sits at another rect.
  private func adopt(_ anchor: HoverAnchor) {
    guard anchor != self.anchor else { return }
    self.anchor = anchor
    presenter.refresh(below: anchor)
  }

  private func close() {
    guard shown != nil else { return }
    shown = nil
    anchor = nil
    onCard = false
    presenter.hide()
  }

  private func closeAfterGrace() {
    after(grace) { [weak self] in self?.close() }
  }

  private func after(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) {
    cancel()
    cancelPending = schedule(interval) { [weak self] in
      self?.cancelPending = nil
      action()
    }
  }

  private func cancel() {
    cancelPending?()
    cancelPending = nil
  }
}
