/// `ms` in the largest whole unit: "12s", "5m", "3h", or "2d". A negative duration returns "0s".
public func compactDuration(_ ms: Int64) -> String {
  let s = max(0, ms / 1000)
  if s < 60 { return "\(s)s" }
  if s < 3600 { return "\(s / 60)m" }
  if s < 86400 { return "\(s / 3600)h" }
  return "\(s / 86400)d"
}

/// How long ago `ms` was, in the units of `compactDuration`. For a time in the future, it returns "0s".
public func ago(_ ms: Int64, now: Int64 = nowMs()) -> String {
  compactDuration(now - ms)
}

/// How long until `ms`, in the units of `ago`: "in 12m", or "now" for a time that has come.
public func fromNow(_ ms: Int64, now: Int64 = nowMs()) -> String {
  ms > now ? "in \(ago(now, now: ms))" : "now"
}
