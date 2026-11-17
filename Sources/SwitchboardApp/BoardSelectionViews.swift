import AppKit
import SwiftUI
import SwitchboardCore

/// The geometry that the Board's selection rectangle reads. Frames are in `BoardView.contentSpace`. Writes
/// here do not redraw the Board.
@MainActor
final class BoardGeometry {
  /// The frame of every card the Board draws. A card that a lazy lane removes while a rectangle is drawn keeps
  /// its last frame, so the rectangle still reaches it after an autoscroll. That frame is removed when the
  /// rectangle ends, unless the card draws again first.
  private(set) var frames: [String: CGRect] = [:]
  var header: CGRect = .zero
  /// A view inside the Board's scroll view, which finds the scroll view.
  weak var anchor: NSView?
  /// Frames whose card views went away while a rectangle was drawn.
  private var pendingDrops: [String: CGRect] = [:]
  /// True while a selection rectangle is drawn. When it turns false, the frames in `pendingDrops` that no view
  /// has written since are removed.
  var marqueeActive = false {
    didSet {
      guard !marqueeActive else { return }
      for (id, frame) in pendingDrops where frames[id] == frame { frames[id] = nil }
      pendingDrops = [:]
    }
  }

  func keepFrames(_ ids: Set<String>) { frames = frames.filter { ids.contains($0.key) } }

  /// Stores the frame that a card view reports. It cancels a pending removal of that card's frame.
  func record(_ id: String, _ frame: CGRect) {
    frames[id] = frame
    pendingDrops[id] = nil
  }

  /// Removes the frame of a card view that went away. While a rectangle is drawn, the removal waits until the
  /// rectangle ends. A second view can draw the same card, and SwiftUI may report its frame before the first
  /// view disappears. The frame is removed only when it is still the one that the departing view wrote.
  func dropFrame(_ id: String, ifStill frame: CGRect?) {
    guard let frame, frames[id] == frame else { return }
    if marqueeActive { pendingDrops[id] = frame } else { frames[id] = nil }
  }

  /// Scrolls toward the edge of the visible area that the pointer is near or past. It returns how far the
  /// content moved under the pointer, in content coordinates, or nil when it did not move.
  func autoscrollStep() -> CGVector? {
    guard let scrollView = anchor?.enclosingScrollView, let window = scrollView.window,
      let document = scrollView.documentView
    else { return nil }
    var pointer = scrollView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    if !scrollView.isFlipped { pointer.y = scrollView.bounds.height - pointer.y }
    let delta = BoardRect.autoscrollDelta(
      pointer: pointer, visible: scrollView.bounds.size, headerHeight: header.height + BoardView.boardPadding)
    guard delta != .zero else { return nil }
    let clip = scrollView.contentView
    let down: CGFloat = document.isFlipped ? 1 : -1
    let old = clip.bounds.origin
    var target = clip.bounds
    target.origin.x += delta.dx
    target.origin.y += delta.dy * down
    let origin = clip.constrainBoundsRect(target).origin
    guard origin != old else { return nil }
    clip.scroll(to: origin)
    scrollView.reflectScrolledClipView(clip)
    return CGVector(dx: origin.x - old.x, dy: (origin.y - old.y) * down)
  }
}

/// The Board's selection rectangle and its click on empty space. The rectangle's state lives here, so a
/// pointer move redraws the rectangle and not every card. The Board redraws only when the selection changes.
struct BoardMarqueeSelection: ViewModifier {
  @EnvironmentObject var model: BoardModel
  let geometry: BoardGeometry
  /// Gives the Board keyboard focus, so Escape reaches it.
  let focus: () -> Void
  @State private var marquee: Marquee?

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .topLeading) {
        if let rect = marquee?.rect {
          Rectangle()
            .fill(Color.accentColor.opacity(0.15))
            .stroke(Color.accentColor.opacity(0.8))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
        }
      }
      .simultaneousGesture(drag)
      .simultaneousGesture(
        SpatialTapGesture(coordinateSpace: .named(BoardView.contentSpace)).onEnded { tap in
          guard onEmptySpace(tap.location) else { return }
          model.clearBoardSelection()
          focus()
        }
      )
      // While the rectangle's pointer rests at an edge, no drag event arrives, so a loop scrolls.
      .task(id: marquee != nil) {
        while marquee != nil, !Task.isCancelled {
          if let moved = geometry.autoscrollStep() {
            marquee?.current.x += moved.dx
            marquee?.current.y += moved.dy
            select()
          }
          try? await Task.sleep(for: .milliseconds(16))
        }
      }
      .onChange(of: marquee != nil) { _, active in geometry.marqueeActive = active }
  }

  /// Draws a selection rectangle from a drag that starts on empty space. ⌘ held at the start adds the cards
  /// to the selection.
  private var drag: some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .named(BoardView.contentSpace))
      .onChanged { value in
        if marquee == nil {
          guard onEmptySpace(value.startLocation) else { return }
          let base = NSEvent.modifierFlags.contains(.command) ? model.multiSelection : []
          marquee = Marquee(start: value.startLocation, current: value.location, base: base)
          focus()
        }
        marquee?.current = value.location
        select()
      }
      .onEnded { _ in marquee = nil }
  }

  private func onEmptySpace(_ point: CGPoint) -> Bool {
    BoardRect.startsSelection(
      at: point, frames: geometry.frames, labelEdge: BoardView.boardPadding + BoardView.labelWidth,
      header: geometry.header)
  }

  private func select() {
    guard let marquee else { return }
    model.selectBoardRect(BoardRect.hits(marquee.rect, frames: geometry.frames), adding: marquee.base)
  }
}

/// A selection rectangle being drawn, from the drag's start to the pointer, in content coordinates.
struct Marquee {
  let start: CGPoint
  var current: CGPoint
  /// The selection that a ⌘-drag adds to.
  let base: Set<String>

  var rect: CGRect { BoardRect.rect(from: start, to: current) }
}

/// Puts an empty AppKit view in the Board's scroll content, so `BoardGeometry` can find the scroll view.
struct BoardScrollAnchor: NSViewRepresentable {
  let geometry: BoardGeometry

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    geometry.anchor = view
    return view
  }

  func updateNSView(_ view: NSView, context: Context) { geometry.anchor = view }
}

/// Makes a card draggable onto a lane. A selected card drags the whole selection.
struct CardDrag: ViewModifier {
  @EnvironmentObject var model: BoardModel
  let id: String
  let enabled: Bool

  func body(content: Content) -> some View {
    let ids = model.boardActionIDs(for: id)
    if !enabled {
      content
    } else if ids.count > 1 {
      content.draggable(BoardDrag.payload(ids)) {
        Label("\(ids.count) sessions", systemImage: "square.stack")
          .padding(8)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      }
    } else {
      content.draggable(id)
    }
  }
}

extension BoardView {
  /// Handles Escape, Space, ⌘⌫, and ⇧-arrows, which change the Board selection. It returns nil for the keys
  /// that move the focus ring or open a card.
  func selectionKey(_ press: KeyPress, removable: Int) -> KeyPress.Result? {
    let modifiers = NavKey.modifiers(press.modifiers)
    switch press.key {
    case .escape where modifiers.isEmpty:
      guard !model.multiSelection.isEmpty else { return .ignored }
      model.clearBoardSelection()
    case .space where modifiers.isEmpty:
      model.toggleFocusedBoardCard()
    case .delete:
      // `removable` is 0 unless two or more sessions are selected.
      guard modifiers == .command, removable > 0, !model.showingDoneRemoval else {
        return .ignored
      }
      model.checkSelectionRemoval()
    default:
      guard modifiers == .shift, case .move(let direction) = NavKey.action(press.key, modifiers: []) else {
        return nil
      }
      model.extendBoardSelection(direction)
    }
    return .handled
  }
}

private struct BoardGeometryKey: EnvironmentKey {
  static let defaultValue: BoardGeometry? = nil
}

extension EnvironmentValues {
  /// Where a Board card records its frame. Cards outside the Board record nothing.
  var boardGeometry: BoardGeometry? {
    get { self[BoardGeometryKey.self] }
    set { self[BoardGeometryKey.self] = newValue }
  }
}
