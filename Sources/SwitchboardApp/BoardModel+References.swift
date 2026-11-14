import Foundation
import SwitchboardCore

/// What the app knows about a reference's issue or pull request.
enum ReferenceLoad: Equatable, Sendable {
  case loading
  case loaded(ReferenceDetails)
  /// GitHub has no such item, or the token can't see it.
  case notFound
  case failed(String)
}

/// The details of each reference whose card opened, by `GitHubRef.key`. Only the reference card observes it, so an
/// answer redraws no other view.
@MainActor
final class ReferenceStore: ObservableObject {
  static let maxEntries = 500

  @Published private(set) var details: [String: ReferenceLoad] = [:]
  /// The keys whose `ref-details` request has not answered yet.
  var inFlight: Set<String> = []

  /// Clears the store before it holds more than `maxEntries` items.
  func store(_ load: ReferenceLoad, for key: String) {
    guard details[key] != load else { return }
    if details[key] == nil, details.count >= Self.maxEntries { details.removeAll() }
    details[key] = load
  }
}

extension BoardModel {
  /// Asks sbd for `ref`'s details. A loaded value stays on screen until the
  /// answer replaces it. While a request for the same item is in flight, it
  /// sends nothing. sbd decides how fresh an answer is, so the app keeps no
  /// time limit of its own. A failure goes to the card, not to `actionError`.
  func loadReference(_ ref: GitHubRef) {
    let key = ref.key
    guard references.inFlight.insert(key).inserted else { return }
    if case .loaded? = references.details[key] {} else { references.store(.loading, for: key) }
    let send = send
    let args: [String: JSON] = ["repo": .string(ref.repo), "number": .number(Double(ref.number))]
    issueWork.async {
      let load: ReferenceLoad
      do {
        switch try JSONCoding.convert(try send("ref-details", args), to: ReferenceReply.self) {
        case .found(let details): load = .loaded(details)
        case .notFound: load = .notFound
        }
      } catch {
        load = .failed("\(error)")
      }
      Task { @MainActor in
        self.references.inFlight.remove(key)
        self.references.store(load, for: key)
      }
    }
  }
}
