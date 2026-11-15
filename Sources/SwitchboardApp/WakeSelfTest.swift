import AppKit
import SwiftTerm

/// A scripted check that input in a stopped session's Claude terminal starts claude again, run by `bin/test-gui`
/// with SB_WAKE_TEST=1 and SB_SELECT. It stops claude three times. After the first stop it posts three keys to the
/// terminal, after the second a click, and after the third a drag, which selects text and must not start claude.
/// It posts each event to the app's event queue, as a typed key or a click arrives. Each step logs whether claude
/// runs to standard error, and the app quits at the end.
@MainActor
enum WakeSelfTest {
  private enum Input: String, CaseIterable {
    case keys, click, drag
  }

  static func start(_ model: BoardModel) {
    let env = ProcessInfo.processInfo.environment
    guard env["SB_WAKE_TEST"] != nil, let session = env["SB_SELECT"] else { return }
    Task { @MainActor in
      await run(model, session)
      log("done")
      NSApp.terminate(nil)
    }
  }

  private static func run(_ model: BoardModel, _ session: String) async {
    let live = { model.allBoard.first { $0.id == session }?.live == true }
    let shown = await until(60) {
      if model.selection != session, model.sessions.contains(where: { $0.id == session }) {
        model.selection = session
      }
      return model.selection == session && live() && TerminalSelfTest.panes().first != nil
    }
    guard shown else { return log("no live terminal") }
    for input in Input.allCases {
      model.stop(session)
      guard await until(30, { !live() }) else { return log("\(input): claude did not stop") }
      // SwiftUI hands the terminal its wake action in the update after the summary changes.
      try? await Task.sleep(for: .seconds(1))
      guard let pane = TerminalSelfTest.panes().first, let window = pane.window else { return log("no pane") }
      post(input, to: pane, in: window)
      let started = await until(input == .drag ? 3 : 30, live)
      log("after \(input): claude runs \(started)")
    }
  }

  private static func post(_ input: Input, to pane: TerminalView, in window: NSWindow) {
    let time = ProcessInfo.processInfo.systemUptime
    switch input {
    case .keys:
      window.makeFirstResponder(pane)
      for _ in 0..<3 {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
            keyCode: TerminalSelfTest.code(for: "a")
          ).map { NSApp.postEvent($0, atStart: false) }
        }
      }
    case .click, .drag:
      let down = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
      let up = input == .drag ? NSPoint(x: down.x + 40, y: down.y) : down
      for (type, point) in [(NSEvent.EventType.leftMouseDown, down), (.leftMouseUp, up)] {
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ).map { NSApp.postEvent($0, atStart: false) }
      }
    }
  }

  /// Checks `condition` every quarter second for up to `seconds`, and returns whether it held.
  private static func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if condition() { return true }
      try? await Task.sleep(for: .seconds(0.25))
    }
    return condition()
  }

  private static func log(_ text: String) { FileHandle.standardError.write(Data("waketest: \(text)\n".utf8)) }
}
