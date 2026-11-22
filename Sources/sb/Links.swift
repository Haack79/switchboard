import Foundation
import SwitchboardCore

/// A session's link as `sb get` prints it: `  link: <id>  <title>  <url>  (<caption>)`.
func linkLine(_ l: ExternalLink) -> String { "  link: \(l.id)  \(l.title)  \(l.url)  (\(l.caption()))".printable }
