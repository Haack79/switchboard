import Foundation
import SwitchboardCore

/// `sb ref`: what sbd knows about one GitHub issue or pull request.
func refCommand(_ a: Args) {
  guard a.positional.count == 1, let text = a.positional.first?.trimmingCharacters(in: .whitespaces) else {
    die("usage: sb ref <owner/name#N | URL | #N> [--repo owner/name] [--json]")
  }
  let repo = a.values["--repo"]
  let bare = text.hasPrefix("#")
  if bare, repo == nil { die("#N needs --repo owner/name") }
  if !bare, repo != nil { die("--repo names the repository of #N, so it does not go with \(text)") }
  let result = call("ref-details", ["ref": .string((repo ?? "") + text)])
  let details: ReferenceDetails
  switch decode(result, as: ReferenceReply.self) {
  case .found(let found): details = found
  case .notFound(let repo, let number): die("\(repo)#\(number) not found, or your GitHub token can't see it")
  }
  if a.json {
    printJSON(result)
    return
  }
  print("\(details.repo)#\(details.number) \(details.kind.rawValue) \(details.state.rawValue)")
  print(details.title)
  let about = [
    details.author.map { "by \($0)" },
    details.labels.isEmpty ? nil : "labels: \(details.labels.joined(separator: ", "))",
  ]
  .compactMap { $0 }
  if !about.isEmpty { print(about.joined(separator: ", ")) }
  let pr = [
    details.checks.map { "checks \($0)" }, details.reviewDecision.map { "review \($0.rawValue)" },
    details.mergeable.map { "mergeable \($0.rawValue)" },
  ].compactMap { $0 }
  if !pr.isEmpty { print(pr.joined(separator: ", ")) }
}
