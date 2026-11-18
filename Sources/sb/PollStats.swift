import Foundation
import SwitchboardCore

/// Prints `sb poll --stats`: the totals, then one line for each trigger and owner of the PR reads.
func printPollStats(_ result: JSON) {
  let report = decode(result, as: GitHubUsage.Report.self)
  func rate(_ value: Double) -> String { String(format: "%.1f", value) }
  print(
    "\(report.requests) requests and \(report.points) points in \(rate(report.hours)) h"
      + " (\(rate(report.requestsPerHour)) requests and \(rate(report.pointsPerHour)) points an hour)")
  for trigger in ReadTrigger.allCases {
    for (owner, r) in (report.reads[trigger.rawValue] ?? [:]).sorted(by: { $0.key < $1.key }) {
      print(
        "  \(trigger.rawValue) \(owner): \(r.reads) reads, \(rate(r.requestsPerHour)) requests"
          + " and \(rate(r.pointsPerHour)) points an hour")
    }
  }
}
