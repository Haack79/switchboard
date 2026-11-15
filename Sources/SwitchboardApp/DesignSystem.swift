import SwiftUI

/// The values that views share so that the same element looks the same everywhere.
enum Design {
  /// The opacity of a tinted badge's background.
  static let badgeTint = 0.18
}

extension View {
  /// A small capsule badge in `color`. A tinted badge draws the color faintly behind text in the color. A filled
  /// badge draws white text on the solid color, for a count that must stand out.
  func pill(_ color: Color, filled: Bool = false) -> some View {
    font(.caption2.bold())
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(Capsule().fill(filled ? color : color.opacity(Design.badgeTint)))
      .foregroundStyle(filled ? .white : color)
  }
}
