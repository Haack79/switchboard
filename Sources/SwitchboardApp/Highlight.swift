import SwiftUI
import SwitchboardCore

/// Highlight, or Remove Highlight while the session is highlighted. A session that `canHighlight` refuses gets no
/// item unless it is highlighted.
struct HighlightMenuItem: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  static func title(for s: SessionSummary) -> String? {
    s.highlighted == true ? "Remove Highlight" : s.canHighlight ? "Highlight" : nil
  }

  var body: some View {
    if let title = Self.title(for: session) {
      Button(title) { model.setHighlighted(session.id, session.highlighted != true) }
    }
  }
}

extension View {
  /// The ring of a highlighted session, `outset` points outside the view's edge.
  func highlightRing(_ on: Bool, cornerRadius: CGFloat, outset: CGFloat) -> some View {
    overlay {
      if on {
        RoundedRectangle(cornerRadius: cornerRadius)
          .strokeBorder(Design.highlight, lineWidth: Design.highlightRingWidth)
          .padding(-outset)
          .allowsHitTesting(false)
      }
    }
  }

  /// VoiceOver's "Priority: Highlighted", so the highlight is not carried by color alone.
  func highlightAccessibility(_ on: Bool) -> some View {
    accessibilityCustomContent(AccessibilityCustomContentKey("Priority"), on ? Text("Highlighted") : nil)
  }
}
