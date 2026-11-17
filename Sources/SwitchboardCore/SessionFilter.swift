import Foundation

/// Which sessions the app shows. Every list, count, and action target reads
/// `shows`, so the views never disagree about what is hidden.
public struct SessionFilter: Equatable, Sendable {
  public var org: OrgFilter

  public init(org: OrgFilter = OrgFilter()) {
    self.org = org
  }

  public var isAll: Bool { org.isAll }

  public func shows(_ s: SessionSummary) -> Bool {
    org.shows(s)
  }

  /// Whether the filter shows `s` and the app can tell that it does. A
  /// session whose org sbd hasn't read shows under an org filter, but its org
  /// may be one that the filter hides, so a destructive action skips it.
  public func surelyShows(_ s: SessionSummary) -> Bool {
    shows(s) && (org.isAll || OrgFilter.key(of: s) != nil)
  }
}
