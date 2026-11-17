import SwiftUI
import SwitchboardCore

/// Highlight, or Remove Highlight while the session is highlighted. A session that `canHighlight` refuses gets no
/// item unless it is highlighted.
struct HighlightMenuItem: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  static func title(for s: SessionSummary) -> String? {
    s.isHighlighted ? "Remove Highlight" : s.canHighlight ? "Highlight" : nil
  }

  var body: some View {
    if let title = Self.title(for: session) {
      Button(title) { model.setHighlighted(session.id, !session.isHighlighted) }
    }
  }
}

extension View {
  /// The ring of a highlighted session, `outset` points outside the view's edge. `cornerRadius` is the view's own
  /// corner radius, and the ring adds `outset` to it.
  func highlightRing(_ on: Bool, cornerRadius: CGFloat, outset: CGFloat) -> some View {
    overlay {
      if on {
        RoundedRectangle(cornerRadius: cornerRadius + outset)
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
