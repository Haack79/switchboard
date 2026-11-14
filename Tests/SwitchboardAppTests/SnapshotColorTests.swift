import AppKit
import Foundation
import QuartzCore
import Testing

@testable import SwitchboardApp

@Suite struct SnapshotVibrancy {
  static let identity: [Float] = [
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ]

  static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

  /// Whether `color`'s sRGB components are `expected`, to three decimal places.
  static func matches(_ color: CGColor, _ expected: [CGFloat]) -> Bool {
    let components =
      color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!.components!
    return components.count == expected.count && zip(components, expected).allSatisfy { abs($0 - $1) < 0.001 }
  }

  @Test func identityKeepsTheColor() {
    let orange = CGColor(srgbRed: 1, green: 0.55, blue: 0.16, alpha: 1)
    #expect(Self.matches(Snapshot.apply(Self.identity, to: orange), [1, 0.55, 0.16, 1]))
  }

  @Test func eachRowIsADotProductPlusItsOffset() {
    // Red takes half of green plus 0.1, green takes blue, blue takes red, and alpha stays.
    let matrix: [Float] = [
      0, 0.5, 0, 0, 0.1,
      0, 0, 1, 0, 0,
      1, 0, 0, 0, 0,
      0, 0, 0, 1, 0,
    ]
    let out = Snapshot.apply(matrix, to: CGColor(srgbRed: 0.2, green: 0.6, blue: 0.4, alpha: 1))
    #expect(Self.matches(out, [0.4, 0.4, 0.2, 1]))
  }

  @Test func clampsToTheUnitRange() {
    let matrix: [Float] = [
      2, 0, 0, 0, 0,
      0, 0, 0, 0, -1,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ]
    let out = Snapshot.apply(matrix, to: CGColor(srgbRed: 0.8, green: 0.5, blue: 0.3, alpha: 1))
    #expect(Self.matches(out, [1, 0, 0.3, 1]))
  }

  @Test func aMatrixOfTheWrongSizeKeepsTheColor() {
    let color = CGColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
    #expect(Snapshot.apply([1, 0, 0], to: color) == color)
  }

  /// A `vibrantColorMatrix` filter, as AppKit puts on sidebar layers. CAFilter is private.
  static func vibrantFilter(_ matrix: [Float]) -> NSObject {
    let type = NSClassFromString("CAFilter") as! NSObject.Type
    let filter =
      type.perform(NSSelectorFromString("filterWithType:"), with: "vibrantColorMatrix").takeUnretainedValue()
      as! NSObject
    let encoding = "{CAColorMatrix=" + String(repeating: "f", count: 20) + "}"
    let value = matrix.withUnsafeBytes { NSValue(bytes: $0.baseAddress!, objCType: encoding) }
    filter.setValue(value, forKey: "inputColorMatrix")
    return filter
  }

  @MainActor @Test func recolorsAFilteredBackgroundAndPutsItBack() {
    // The offsets make the output orange for any input. AppKit's sidebar matrices color a status dot the same way.
    let matrix: [Float] = [
      0, 0, 0, 0, 1,
      0, 0, 0, 0, 0.5,
      0, 0, 0, 0, 0,
      0, 0, 0, 1, 0,
    ]
    let root = CALayer()
    let dot = CALayer()
    dot.backgroundColor = Self.white
    dot.filters = [Self.vibrantFilter(matrix)]
    root.addSublayer(dot)
    let restore = Snapshot.applyVibrancy(root)
    #expect(Self.matches(dot.backgroundColor!, [1, 0.5, 0, 1]))
    restore()
    #expect(dot.backgroundColor == Self.white)
  }

  @MainActor @Test func leavesLayersWithoutTheFilterAlone() {
    let root = CALayer()
    let child = CALayer()
    child.backgroundColor = Self.white
    root.addSublayer(child)
    let restore = Snapshot.applyVibrancy(root)
    #expect(child.backgroundColor == Self.white)
    restore()
    #expect(child.backgroundColor == Self.white)
  }
}
