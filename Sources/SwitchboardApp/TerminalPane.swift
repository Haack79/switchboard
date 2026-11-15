import AppKit
import SwiftTerm
import SwiftUI

/// A terminal that attaches to one of sbd's tmux panes. Closing the view ends
/// only the tmux client, so the pane keeps running in sbd.
struct TerminalPane: NSViewRepresentable {
  let command: [String]
  /// Runs on the main thread after the tmux client exits.
  var onExit: (() -> Void)? = nil
  /// The terminal takes keyboard focus once it is in a window, then calls `onFocus`.
  var takesFocus = false
  var onFocus: (() -> Void)? = nil
  /// When true, Shift+Return sends ESC CR, which Claude Code reads as a new line in its prompt. Leave it false
  /// for a shell, where Shift+Return sends CR and runs the command.
  var newlineOnShiftReturn = false
  /// Reads the blocks of the session's recent assistant messages for the copy button over quotes and code blocks. A pane
  /// without one shows no copy button.
  var loadBlockSources: BlockSourcesLoader? = nil
  /// Runs on a key or a click aimed at this terminal, as `TerminalWake` decides. Pass it only while claude is stopped.
  var wake: (() -> Void)? = nil

  func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

  func makeNSView(context: Context) -> PaddedTerminalView {
    let padded = PaddedTerminalView(frame: .zero)
    let view = padded.terminal
    view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    view.optionAsMetaKey = true
    view.processDelegate = context.coordinator
    let env = ProcessInfo.processInfo.environment
    var childEnv = ["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=\(env["LANG"] ?? "en_US.UTF-8")"]
    for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
      if let value = env[key] { childEnv.append("\(key)=\(value)") }
    }
    view.startProcess(executable: command[0], args: Array(command.dropFirst()), environment: childEnv)
    updateNSView(padded, context: context)
    return padded
  }

  func updateNSView(_ view: PaddedTerminalView, context: Context) {
    view.onFocus = onFocus
    view.wake = wake
    view.focusWhenInWindow = takesFocus
    view.terminal.newlineOnShiftReturn = newlineOnShiftReturn
    view.showCopyButtons(loadBlockSources)
  }

  static func dismantleNSView(_ view: PaddedTerminalView, coordinator: Coordinator) {
    view.showCopyButtons(nil)
    view.stopWakeMonitor()
    view.terminal.terminate()
  }

  final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
    let onExit: (() -> Void)?

    init(onExit: (() -> Void)?) { self.onExit = onExit }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
      DispatchQueue.main.async {
        source.feed(text: "\r\n[detached from Switchboard's terminal]\r\n")
        self.onExit?()
      }
    }
  }
}

/// Holds a terminal view inset from its left and right edges, and fills the inset with the terminal's
/// background color. SwiftTerm computes columns and rows from its own frame, so the terminal sizes itself
/// to the inset width.
final class PaddedTerminalView: NSView {
  static let horizontalPadding: CGFloat = 10

  let terminal = ThemedTerminalView(frame: .zero)
  // SwiftTerm builds its mouse tracking area and its scroller hit test from its frame as if the frame were in
  // its own coordinates. The terminal therefore sits at the origin of this holder, and the holder is inset.
  private let holder = NSView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    wantsLayer = true
    holder.addSubview(terminal)
    addSubview(holder)
    placeTerminal()
    applyBackground()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  var onFocus: (() -> Void)?
  /// While true, the terminal takes keyboard focus as soon as this view is in a window.
  var focusWhenInWindow = false {
    didSet { focusIfAsked() }
  }

  /// The monitor reads this when an event arrives, because `updateNSView` replaces it on every refresh. The monitor
  /// runs only while this is set and the view is in a window.
  var wake: (() -> Void)? {
    didSet { updateWakeMonitor() }
  }
  private var wakeMonitor: Any?
  /// Where a left click aimed at the terminal went down, in window coordinates.
  private var clickStart: CGPoint?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateWakeMonitor()
    focusIfAsked()
  }

  /// SwiftTerm's key and mouse handlers are not open to subclasses, so a local monitor sees the events first.
  /// The monitor returns every event unchanged. The summary can still say stopped just after claude starts,
  /// and swallowing then would eat real keys. tmux drops a key sent to the stopped pane.
  private func updateWakeMonitor() {
    guard wake != nil, window != nil else { return stopWakeMonitor() }
    guard wakeMonitor == nil else { return }
    wakeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseUp]) {
      [weak self] event in
      self?.wakeIfAimed(event)
      return event
    }
  }

  func stopWakeMonitor() {
    wakeMonitor.map(NSEvent.removeMonitor)
    wakeMonitor = nil
    clickStart = nil
  }

  private func wakeIfAimed(_ event: NSEvent) {
    guard let wake, let window, event.window === window else { return }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    switch event.type {
    case .keyDown:
      if window.firstResponder === terminal && TerminalWake.wakes(key: modifiers) { wake() }
    case .leftMouseDown:
      clickStart = hitsTerminal(event.locationInWindow) ? event.locationInWindow : nil
    case .leftMouseUp:
      if let start = clickStart, TerminalWake.isClick(down: start, up: event.locationInWindow, modifiers: modifiers) {
        wake()
      }
      clickStart = nil
    default: break
    }
  }

  /// A click on the copy button or the scroller hits that view instead, so it doesn't wake.
  private func hitsTerminal(_ point: CGPoint) -> Bool {
    // `hitTest` takes a point in the superview's coordinates.
    guard let content = window?.contentView, let frame = content.superview else { return false }
    return content.hitTest(frame.convert(point, from: nil)) === terminal
  }

  private(set) var copyOverlay: TerminalCopyOverlay?

  /// Starts the copy button over quotes and code blocks with `loadBlockSources`, or stops it when that is nil. A
  /// running overlay keeps the loader it started with, because SwiftUI passes a new closure on every update.
  func showCopyButtons(_ loadBlockSources: BlockSourcesLoader?) {
    if let loadBlockSources {
      if copyOverlay == nil { copyOverlay = TerminalCopyOverlay(host: self, loadBlockSources: loadBlockSources) }
    } else {
      copyOverlay?.stop()
      copyOverlay = nil
    }
  }

  private func focusIfAsked() {
    guard focusWhenInWindow, let window, window.makeFirstResponder(terminal) else { return }
    focusWhenInWindow = false
    // SwiftUI forbids a state change while it updates the view, and this can run in that update.
    DispatchQueue.main.async { [onFocus] in onFocus?() }
  }

  /// The padded view that holds `terminal`, or nil when the terminal is not in one.
  static func containing(_ terminal: TerminalView) -> PaddedTerminalView? {
    terminal.superview?.superview as? PaddedTerminalView
  }

  override func resizeSubviews(withOldSize oldSize: NSSize) {
    placeTerminal()
    copyOverlay?.scheduleRefresh()
  }

  private func placeTerminal() {
    let pad = Self.horizontalPadding
    holder.frame = NSRect(x: pad, y: 0, width: max(0, bounds.width - 2 * pad), height: bounds.height)
    terminal.frame = holder.bounds
  }

  // A click, drag, or scroll in the padding goes to the terminal, which clamps it to the nearest column.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self || hit === holder ? terminal : hit
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyBackground()
  }

  // AppKit does not guarantee that the terminal sees an appearance change before this view does, so this
  // view computes the color from the theme instead of reading it from the terminal.
  private func applyBackground() {
    layer?.backgroundColor = TerminalTheme(appearance: effectiveAppearance).background.cgColor
  }
}
