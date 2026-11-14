import AppKit
import SwiftTerm
import SwiftUI

/// A scripted check of the shell pane, run by `bin/test-gui`. SB_SHELL_TEST=<folder> makes the app run each
/// command that a script writes to <folder>/cmd, one at a time. When the command is done, the app appends
/// "shelltest: <command> -> <result>" to standard error and then deletes the file. The commands are:
/// `click close` clicks the × on the Shell pane's label with mouse events at the button's place in the
/// window. `click open` clicks Open Shell on the Claude pane's label the same way. SwiftUI builds no
/// accessibility elements without an assistive app, so the test can't press a button by its label.
/// `menu <menu> <item>` runs a menu item. `show-terminal` shows the terminals of a chat pane or an Inbox item,
/// as their Terminal toggle does. `select <session>` selects a session. `type <text>` types the text and
/// Return into the shell pane. `ctrl-d` types Ctrl-D there. `panes` reports how many terminals the window
/// shows. `cmd-w` sends ⌘W to the menu bar and reports the menu item that owns ⌘W. `nav-keys` sends each of
/// `NavShortcuts` to the menu bar as a US keyboard types it, and reports the title of the menu item that ran.
/// `mouse <3|4>` posts a press of mouse button 4 or 5 (button numbers 3 and 4) over the window to the app's
/// event queue, so it passes through the app's event monitors as a real press does. `where` reports the place
/// that the window shows. `snapshot <path>` draws the window as SB_SNAPSHOT does. `cmd-click <session>` ⌘-clicks
/// the session's sidebar row with mouse events at the row's place in the window. `detail` reports
/// "N sessions selected" while the detail pane shows the multi-selection, else the place that the window shows.
/// `click-delete-selected` clicks Delete N Sessions… in the detail pane the same way. `sheet` reports the removal
/// sheet's step: `none`, `checking`, or `confirming <number of sessions it deletes>`.
@MainActor
enum ShellSelfTest {
  static let folder = ProcessInfo.processInfo.environment["SB_SHELL_TEST"]

  static func start(_ model: BoardModel) {
    guard let folder else { return }
    let path = "\(folder)/cmd"
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
      MainActor.assumeIsolated {
        guard let command = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        log("\(line) -> \(run(line, model))")
        // The script reads the result once the file is gone, so the file goes only after the log line.
        try? FileManager.default.removeItem(atPath: path)
      }
    }
  }

  private static func run(_ line: String, _ model: BoardModel) -> String {
    let words = line.split(separator: " ", maxSplits: 1).map(String.init)
    let rest = words.count > 1 ? words[1] : ""
    switch words.first {
    case "click":
      let (target, offset): (TerminalView?, CGFloat) = rest == "close" ? (shellPane(), 6) : (panes().first, 25)
      guard let window, let pane = target else { return "no pane" }
      guard let point = labelPoint(of: pane, offset: offset) else { return "no label" }
      guard TerminalSelfTest.click(at: point, in: window) else { return "no event" }
      return "clicked at \(Int(point.x)),\(Int(point.y))"
    case "show-terminal":
      model.showingTerminal = true
      return "shown"
    case "menu":
      let names = rest.split(separator: " ", maxSplits: 1).map(String.init)
      guard names.count == 2, let menu = NSApp.mainMenu?.item(withTitle: names[0])?.submenu else { return "no menu" }
      // SwiftUI sets the items' titles when the menu opens.
      menu.delegate?.menuNeedsUpdate?(menu)
      menu.update()
      let index = menu.indexOfItem(withTitle: names[1])
      guard index >= 0 else { return "not found in \(menu.items.map(\.title))" }
      guard menu.items[index].isEnabled else { return "disabled" }
      menu.performActionForItem(at: index)
      return "ran"
    case "select":
      model.selection = rest
      return "selected"
    case "type":
      guard let pane = shellPane() else { return "no shell pane" }
      for char in rest.map(String.init) {
        TerminalSelfTest.key(pane, char, code: TerminalSelfTest.code(for: char))
      }
      TerminalSelfTest.key(pane, "\r", code: 36)
      return "typed"
    case "ctrl-d":
      guard let pane = shellPane() else { return "no shell pane" }
      TerminalSelfTest.key(pane, "\u{04}", "d", code: TerminalSelfTest.code(for: "d"), mods: .control)
      return "typed"
    case "panes":
      return "\(panes().count)"
    case "cmd-w":
      guard let window,
        let event = NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w",
          isARepeat: false, keyCode: TerminalSelfTest.code(for: "w"))
      else { return "no window" }
      let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) == true
      let owner = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first {
        $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == .command
      }
      return "handled \(handled) by \(owner?.title ?? "no item")"
    case "nav-keys":
      guard let window else { return "no window" }
      return NavShortcuts.all.map { menuItem(running: $0, in: window) }.joined(separator: "; ")
    case "mouse":
      guard let window else { return "no window" }
      guard let button = Int(rest), let event = otherMouseDown(button, in: window) else { return "no event" }
      NSApp.postEvent(event, atStart: false)
      return "posted"
    case "where":
      return "\(model.location.place)"
    case "cmd-click":
      return click(anchor: rest, modifiers: .command, throughWindow: true)
    case "detail":
      return model.showsMultiSelection ? DoneRemovalText.selected(model.multiSelected.count) : "\(model.location.place)"
    case "click-delete-selected":
      return click(anchor: "delete-selected", modifiers: [], throughWindow: false)
    case "sheet":
      switch model.doneRemoval {
      case nil: return "none"
      case .checking: return "checking"
      case .confirming(let plan, _): return "confirming \(plan.remove.count)"
      }
    case "snapshot":
      Snapshot.write(to: rest)
      return "wrote"
    default:
      return "unknown command"
    }
  }

  /// How far into its leading edge `click(anchor:)` clicks a view: past a row's padding, onto a button's icon.
  private static let clickInset: CGFloat = 12

  /// Clicks `clickInset` pt into the leading edge of the view whose `clickAnchor` is `name`, at its vertical
  /// middle, and reports the type of the view that the window hits there. Without `throughWindow`, the mouse-down
  /// goes to that view. A window that is not key drops a first click on a button, and a hidden launch never makes
  /// its window key. A sidebar row needs the window, because the window's handling of the mouse-down selects the row.
  private static func click(
    anchor name: String, modifiers: NSEvent.ModifierFlags, throughWindow: Bool
  ) -> String {
    guard let window, let root = window.contentView else { return "no window" }
    guard let anchor = ClickAnchorView.find(name, in: root) ?? scrollIntoView(name, in: root) else {
      return "no \(name)"
    }
    let frame = anchor.convert(anchor.bounds, to: nil)
    let point = NSPoint(x: frame.minX + clickInset, y: frame.midY)
    guard let hit = (root.superview ?? root).hitTest(point) else { return "nothing at \(name)" }
    guard TerminalSelfTest.click(at: point, in: window, modifiers: modifiers, on: throughWindow ? nil : hit) else {
      return "no event"
    }
    return "clicked at \(Int(point.x)),\(Int(point.y)) on \(type(of: hit))"
  }

  /// The anchor named `name` in a row of a table under `view`, after that table scrolls the row into view. A
  /// SwiftUI List builds views only for the rows near its visible area.
  private static func scrollIntoView(_ name: String, in view: NSView) -> ClickAnchorView? {
    for table in tables(in: view) {
      for row in 0..<table.numberOfRows {
        table.scrollRowToVisible(row)
        table.layoutSubtreeIfNeeded()
        if let rowView = table.rowView(atRow: row, makeIfNecessary: true),
          let anchor = ClickAnchorView.find(name, in: rowView)
        {
          return anchor
        }
      }
    }
    return nil
  }

  private static func tables(in view: NSView) -> [NSTableView] {
    (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
  }

  /// Reports the menu item that `shortcut` runs. When none runs, it reports the item that owns the key and
  /// whether that item is enabled. The event has ⇧ when the character is a shifted one, such as "}", because
  /// a keyboard sends ⇧⌘] that way.
  private static func menuItem(running shortcut: KeyboardShortcut, in window: NSWindow) -> String {
    let char = String(shortcut.key.character)
    let (code, shift) = TerminalSelfTest.keystroke(for: char)
    let flags: NSEvent.ModifierFlags = shift ? [.command, .shift] : .command
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: char, charactersIgnoringModifiers: char,
        isARepeat: false, keyCode: code)
    else { return "\(char) no event" }
    var ran: String?
    let observer = NotificationCenter.default.addObserver(
      forName: NSMenu.didSendActionNotification, object: nil, queue: nil
    ) {
      ran = ($0.userInfo?["MenuItem"] as? NSMenuItem)?.title
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
    if let ran { return "\(char) ran \(ran)" }
    let owner = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.keyEquivalent == char }
    return "\(char) ran none" + (owner.map { " (\($0.title) is \($0.isEnabled ? "enabled" : "disabled"))" } ?? "")
  }

  /// A press of the mouse button with number `button` at the window's center, or with no window when `window`
  /// is nil. AppKit's mouse event API sets no button number, so the number goes into the event's Core Graphics copy.
  static func otherMouseDown(_ button: Int, in window: NSWindow? = nil) -> NSEvent? {
    let center = window.map { NSPoint(x: $0.frame.width / 2, y: $0.frame.height / 2) } ?? .zero
    guard
      let event = NSEvent.mouseEvent(
        with: .otherMouseDown, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
      let cg = event.cgEvent
    else { return nil }
    cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
    return NSEvent(cgEvent: cg)
  }

  /// The point `offset` pt into the button on the pane's label. The label is a bar about 18 pt tall above the
  /// pane. Its button follows the label's text. The label starts at the padded view's edge, which is left of
  /// the inset terminal. A terminal outside a padded view gives nil, because its own frame would put the click
  /// beside the button.
  static func labelPoint(of pane: TerminalView, offset: CGFloat) -> NSPoint? {
    guard let column = PaddedTerminalView.containing(pane) else { return nil }
    let frame = column.convert(column.bounds, to: nil)
    let buttonX = frame.minX + SessionView.labelPadding + SessionView.labelWidth + SessionView.labelSpacing
    return NSPoint(x: buttonX + offset, y: frame.maxY + 9)
  }

  private static var window: NSWindow? { TerminalSelfTest.window }

  private static func panes() -> [TerminalView] { TerminalSelfTest.panes() }

  /// The right terminal, when the window shows two.
  private static func shellPane() -> TerminalView? {
    let panes = panes()
    return panes.count == 2 ? panes.last : nil
  }

  private static func log(_ text: String) { FileHandle.standardError.write(Data("shelltest: \(text)\n".utf8)) }
}

extension View {
  /// Puts a `ClickAnchorView` named `name` behind this view while SB_SHELL_TEST runs, so ShellSelfTest can click
  /// this view at its place in the window. SwiftUI builds no accessibility elements without an assistive app.
  @ViewBuilder func clickAnchor(_ name: String) -> some View {
    if ShellSelfTest.folder != nil { background(ClickAnchor(name: name)) } else { self }
  }
}

private struct ClickAnchor: NSViewRepresentable {
  let name: String

  func makeNSView(context: Context) -> ClickAnchorView { ClickAnchorView() }

  func updateNSView(_ view: ClickAnchorView, context: Context) { view.name = name }
}

/// An empty view with the frame of the view that it is the background of.
final class ClickAnchorView: NSView {
  var name = ""

  /// The anchored view gets every click.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  static func find(_ name: String, in view: NSView) -> ClickAnchorView? {
    if let anchor = view as? ClickAnchorView, anchor.name == name { return anchor }
    for subview in view.subviews {
      if let found = find(name, in: subview) { return found }
    }
    return nil
  }
}
