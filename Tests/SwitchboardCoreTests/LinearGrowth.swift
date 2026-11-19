import Testing

/// The checks for a linear scan.
///
/// A wall-clock bound fails a correct scan on a busy CI runner, so these checks compare two sizes measured in the same run.
/// A linear scan's time grows by about `growth` from the small input to the large one. A quadratic scan's time grows by `growth` squared.
enum LinearGrowth {
  /// The size of the large input.
  static let largeCount = 2_000
  fileprivate static let growth = 8
  /// A linear scan's ratio stays near `growth`. A quadratic scan's ratio comes near `growth` squared.
  fileprivate static let maxRatio = 3 * growth
  fileprivate static let rounds = 3
}

/// Expects the time of `work` to grow linearly with its input.
///
/// `input` builds the input of a size. Every part of the input must grow with that size, so that a scan that does work for each pair of parts is quadratic.
/// The two sizes alternate for several rounds, and the fastest round of each size counts. A burst of load on a shared runner changes the result only if it slows every round of one size.
/// - Returns: the large input and the result of `work` on it.
func expectLinearGrowth<Input, Output>(
  _ input: (Int) -> Input, sourceLocation: SourceLocation = #_sourceLocation, _ work: (Input) -> Output
) -> (input: Input, output: Output) {
  let small = input(LinearGrowth.largeCount / LinearGrowth.growth)
  let large = input(LinearGrowth.largeCount)
  var output: Output?
  var fastestSmall = ContinuousClock().measure { _ = work(small) }
  var fastestLarge = ContinuousClock().measure { output = work(large) }
  for _ in 1..<LinearGrowth.rounds {
    fastestSmall = min(fastestSmall, ContinuousClock().measure { _ = work(small) })
    fastestLarge = min(fastestLarge, ContinuousClock().measure { _ = work(large) })
  }

  #expect(
    fastestLarge < fastestSmall * LinearGrowth.maxRatio,
    "small input took \(fastestSmall), large input took \(fastestLarge)", sourceLocation: sourceLocation)
  return (large, output!)
}

struct LinearGrowthTests {
  @Test func aQuadraticScanFails() {
    withKnownIssue {
      _ = expectLinearGrowth({ Array(repeating: 1, count: $0 * 2) }) { values in
        var sum = 0
        for a in values { for b in values { sum &+= a &* b } }
        return sum
      }
    }
  }
}
