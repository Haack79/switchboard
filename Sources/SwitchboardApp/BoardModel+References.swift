import Foundation
import SwitchboardCore

/// What the app knows about a reference's issue or pull request.
enum ReferenceLoad: Equatable, Sendable {
  case loading
  case loaded(ReferenceDetails)
  case failed(String)
}

extension BoardModel {
  static let maxReferenceDetails = 500

  /// Asks sbd for `ref`'s details. A loaded value stays on screen until the
  /// answer replaces it. While a request for the same item is in flight, it
  /// sends nothing. sbd decides how fresh an answer is, so the app keeps no
  /// time limit of its own. A failure goes to the card, not to `actionError`.
  func loadReference(_ ref: GitHubRef) {
    let key = ref.key
    guard referencesInFlight.insert(key).inserted else { return }
    if case .loaded? = referenceDetails[key] {} else { store(.loading, for: key) }
    let send = send
    let args: [String: JSON] = ["repo": .string(ref.repo), "number": .number(Double(ref.number))]
    issueWork.async {
      let load: ReferenceLoad
      do {
        load = .loaded(try JSONCoding.convert(try send("ref-details", args), to: ReferenceDetails.self))
      } catch {
        load = .failed("\(error)")
      }
      Task { @MainActor in
        self.referencesInFlight.remove(key)
        self.store(load, for: key)
      }
    }
  }

  /// Clears the store before it holds more than `maxReferenceDetails` items.
  /// An open card for `key` is measured again, because the answer changes
  /// its height.
  private func store(_ load: ReferenceLoad, for key: String) {
    if referenceDetails[key] == nil, referenceDetails.count >= Self.maxReferenceDetails {
      referenceDetails.removeAll()
    }
    referenceDetails[key] = load
    if let card = referenceCard, card.shown.flatMap({ GitHubRef(parsing: $0)?.key }) == key { card.refreshShown() }
  }
}
