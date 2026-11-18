import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func session(_ id: String, named name: String) -> SessionSummary {
  var s = needsItem(id)
  s.name = name
  return s
}

/// Copy Link puts the session's id link on the clipboard as a Markdown link labeled with its name.
@MainActor
@Suite struct CopyLinkTests {
  /// Runs the body with a pasteboard of its own, so a test never reads or changes the user's clipboard. The
  /// pasteboard is released afterwards.
  func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
    let board = NSPasteboard(name: NSPasteboard.Name("copy-link-test-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    try body(board)
  }

  @Test func copiesAPlainNameAsAMarkdownLinkToTheId() {
    withPasteboard { board in
      CopyLinkMenuItem.copy(session("seb4ec", named: "fix-cache"), to: board)

      #expect(board.string(forType: .string) == "[fix-cache](switchboard://session/seb4ec)")
    }
  }

  /// A bracket in the name would end the label early, so it gets a backslash.
  @Test func escapesTheBracketsInAName() {
    withPasteboard { board in
      CopyLinkMenuItem.copy(session("seb4ec", named: "fix [wip]"), to: board)

      #expect(board.string(forType: .string) == #"[fix \[wip\]](switchboard://session/seb4ec)"#)
    }
  }

  @Test(arguments: ["fix-cache", "fix [wip]", "Fix `sb ls` *now* <x>", "first line\nsecond line"])
  func copiesWhatSessionLinkMarkdownBuilds(_ name: String) {
    withPasteboard { board in
      CopyLinkMenuItem.copy(session("seb4ec", named: name), to: board)

      #expect(board.string(forType: .string) == SessionLink.markdown(name: name, id: "seb4ec"))
    }
  }

  @Test func replacesAnEarlierValueOfAnotherType() {
    withPasteboard { board in
      board.clearContents()
      board.setString("<b>earlier</b>", forType: .html)

      CopyLinkMenuItem.copy(session("seb4ec", named: "fix-cache"), to: board)

      #expect(board.string(forType: .html) == nil)
    }
  }
}
