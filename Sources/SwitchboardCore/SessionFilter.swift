import Foundation

/// Which sessions the app shows: those that both the org filter and the group
/// filter allow. Every list, count, and action target reads `shows`, so the
/// views never disagree about what is hidden.
public struct SessionFilter: Equatable, Sendable {
  public var org: OrgFilter
  public var group: GroupFilter
  /// The group ids that sbd last listed, or nil before it answers.
  public var knownGroups: Set<String>?

  public init(org: OrgFilter = OrgFilter(), group: GroupFilter = GroupFilter(), knownGroups: Set<String>? = nil) {
    self.org = org
    self.group = group
    self.knownGroups = knownGroups
  }

  public var isAll: Bool { org.isAll && group.isAll }

  public func shows(_ s: SessionSummary) -> Bool {
    org.shows(s) && group.shows(s, known: knownGroups)
  }

  /// Whether the filter shows `s` and the app can tell that it does. A
  /// session whose org sbd hasn't read shows under an org filter, but its org
  /// may be one that the filter hides. A session whose group sbd's last
  /// `group-ls` answer doesn't list may be in a group that the filter hides.
  /// A destructive action therefore skips both.
  public func surelyShows(_ s: SessionSummary) -> Bool {
    shows(s) && (org.isAll || OrgFilter.key(of: s) != nil)
      && (group.isAll || GroupFilter.isListed(s, known: knownGroups))
  }

  /// Which filters are on, or nil when neither is.
  public enum Scope: Equatable, Sendable {
    case orgs, groups, both
  }

  public var scope: Scope? {
    switch (org.isAll, group.isAll) {
    case (true, true): nil
    case (false, true): .orgs
    case (true, false): .groups
    case (false, false): .both
    }
  }

  /// What the toolbar says: "All Sessions", the org filter's label, the group
  /// filter's label, or both as "PostHog · Infra +1".
  public func label(orgEntries: [FilterEntry], groupEntries: [FilterEntry]) -> String {
    switch scope {
    case nil: return "All Sessions"
    case .orgs: return org.label(orgEntries)
    case .groups: return group.label(groupEntries)
    case .both:
      return "\(Self.short(org.selectedTitles(orgEntries))) · \(Self.short(group.selectedTitles(groupEntries)))"
    }
  }

  private static func short(_ titles: [String]) -> String {
    guard let first = titles.first else { return "" }
    return titles.count == 1 ? first : "\(first) +\(titles.count - 1)"
  }
}
