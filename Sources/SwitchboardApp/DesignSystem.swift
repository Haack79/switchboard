import SwiftUI

/// The values that views share so that the same element looks the same everywhere.
enum Design {
  /// The opacity of a tinted badge's background.
  static let badgeTint = 0.18
}

/// How large a `pill` badge draws.
enum PillSize {
  /// Beside a name in a list, such as a chat's unread count.
  case small
  /// On its own in a card or a header, such as a session's state.
  case regular
}

extension View {
  /// A capsule badge in `color`. A tinted badge draws the color faintly behind text in the color, or behind primary
  /// text when `plainText` is true, because colored text on its own tint is hard to read in a sentence. A filled badge
  /// draws white text on the solid color, for a count that must stand out.
  func pill(_ color: Color, size: PillSize = .small, filled: Bool = false, plainText: Bool = false) -> some View {
    font(size == .small ? .caption2.bold() : .caption.bold())
      .padding(.horizontal, size == .small ? 5 : 6)
      .padding(.vertical, size == .small ? 1 : 2)
      .background(Capsule().fill(filled ? color : color.opacity(Design.badgeTint)))
      .foregroundStyle(filled ? AnyShapeStyle(.white) : plainText ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
  }
}
