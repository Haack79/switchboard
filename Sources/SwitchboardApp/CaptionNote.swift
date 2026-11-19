import SwiftUI
import SwitchboardCore

/// A caption line with an icon under a session's name. The tooltip shows the full text, with session names in
/// place of session ids.
struct CaptionNote<Style: ShapeStyle>: View {
  @Environment(\.sessionNames) private var names
  let text: String
  let icon: String
  let style: Style

  var body: some View {
    Label {
      InlineText(plain: text, links: false)
    } icon: {
      Image(systemName: icon)
    }
    .font(.caption)
    .foregroundStyle(style)
    .lineLimit(2)
    .help(names.replacingIDs(in: text))
  }
}
