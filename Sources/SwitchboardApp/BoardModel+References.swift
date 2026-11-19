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
  /// How many fresh reads each key has started. An answer is stored only when no fresh read started after its own
  /// request, so a cached answer never replaces a fresh one.
  var freshReads: [String: Int] = [:]

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
    guard references.inFlight.insert(ref.key).inserted else { return }
    readReference(ref, fresh: false)
  }

  /// Asks sbd to read `ref` from GitHub again, past its cache, even while another read is in flight. The answer
  /// replaces the stored details as `loadReference`'s does.
  func checkReference(_ ref: GitHubRef) {
    references.inFlight.insert(ref.key)
    readReference(ref, fresh: true)
  }

  private func readReference(_ ref: GitHubRef, fresh: Bool) {
    let key = ref.key
    if fresh { references.freshReads[key, default: 0] += 1 }
    let generation = references.freshReads[key, default: 0]
    if case .loaded? = references.details[key] {} else { references.store(.loading, for: key) }
    let send = send
    var args: [String: JSON] = ["repo": .string(ref.repo), "number": .number(Double(ref.number))]
    if fresh { args["fresh"] = true }
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
        guard self.references.freshReads[key, default: 0] == generation else { return }
        self.references.inFlight.remove(key)
        self.references.store(load, for: key)
      }
    }
  }
}
