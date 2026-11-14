import Foundation

extension DeployComment {
  /// The login of the bot that writes the comment. Only a GitHub App's login
  /// ends in [bot], so no person can pass for it.
  public static let author = "deployment-status-posthog[bot]"
}

/// One environment's progress for a deploy wait that names a service.
public struct EnvironmentDeploy: Equatable, Sendable {
  public var state: DeployState
  /// The html_url of the PostHog/charts state-deploy.yml run, when the poller found it.
  public var run: String?

  public init(state: DeployState, run: String? = nil) {
    self.state = state
    self.run = run
  }
}

extension ServiceDeployState {
  /// Whether a charts sync job says when the service finished deploying to
  /// `environment`. A manual promotion to prod, for a service that requires
  /// prod approval, starts no sync job.
  public func needsSync(in environment: DeployEnvironment) -> Bool {
    environment == .dev || !requiresProdApproval
  }

  /// Whether the service builds from `repository`. A state file that names no
  /// repository builds from any.
  public func builds(from repository: String) -> Bool {
    self.repository.map { Dependencies.sameRepo($0, repository) } ?? true
  }
}

extension DeployState {
  /// The state of `service` in `environment`. An environment with no sync job
  /// counts as deployed once its commit contains the merge.
  public static func of(
    _ service: ServiceDeployState, in environment: DeployEnvironment, ancestry: DeployedAncestry,
    sync: ChartsDeployJobs.State?
  ) -> DeployState {
    if ancestry == .contains, !service.needsSync(in: environment) { return .deployed }
    return DeployState(ancestry: ancestry, sync: sync)
  }
}

extension Wait {
  public static let posthogRepository = "PostHog/posthog"
  public static let chartsRepository = "PostHog/charts"

  /// Whether the wait needs its PR read at the pending rate. A deploy wait
  /// that names a service doesn't need it once the PR merged. The service's
  /// state file decides that wait. A PR that the poller hasn't read yet needs
  /// it.
  public func readsPRWhilePending(_ pr: SwitchboardCore.PullRequest?) -> Bool {
    !(kind == .deploy && service != nil && pr?.state == .merged)
  }

  /// The environments that a deploy wait names.
  public var deployEnvironments: [DeployEnvironment] { DeployEnvironment.named(environment ?? "prod") ?? [] }

  /// What happened, when a deploy wait can resolve from the PR and its
  /// comments, or nil while it stays open. A merged PR of a wait that names a
  /// service returns nil, because `serviceDeployResolution` decides it.
  ///
  /// The deploy comment covers only the main posthog app. It decides a
  /// PostHog/posthog PR. Nothing that sbd reads shows a PostHog/charts PR or a
  /// PR in another repository deploy. Those resolve when they merge.
  public func deployResolution(of pr: SwitchboardCore.PullRequest, comments: [PRComment]) -> String? {
    switch pr.state {
    case .open: return nil
    case .closed: return "it closed without merging"
    case .merged: break
    }
    if service != nil { return nil }
    if Dependencies.sameRepo(pr.repo, Wait.posthogRepository) {
      let comment = comments.lazy.filter { $0.author == DeployComment.author }
        .compactMap { $0.body.flatMap(DeployComment.parse) }.last
      guard let comment, deployEnvironments.allSatisfy({ comment.state(in: $0) == .deployed }) else { return nil }
      return deployedOutcome
    }
    if Dependencies.sameRepo(pr.repo, Wait.chartsRepository) {
      return "it merged, and Switchboard can't read ArgoCD to see it deploy"
    }
    return "it merged, and Switchboard has no deploy signal for \(pr.repo)"
  }

  /// What happened, when a deploy wait that names a service can resolve, or
  /// nil while it stays open. `state` is the parsed state file, or nil when
  /// PostHog/charts has no state file for the service. `environments` holds
  /// each environment that the poller could decide. A missing entry keeps the
  /// wait open.
  public func serviceDeployResolution(
    _ state: ServiceDeployState?, pr: SwitchboardCore.PullRequest,
    environments: [DeployEnvironment: EnvironmentDeploy]
  ) -> String? {
    switch ServiceDeployVerdict.of(
      service: service ?? "", state, pr: pr, environments: deployEnvironments, progress: environments)
    {
    case .deployed?: deployedOutcome
    case .stuck(let reason)?: reason
    case nil: nil
    }
  }

  private var deployedOutcome: String {
    "it deployed to " + deployEnvironments.map(\.rawValue).joined(separator: " and ")
  }
}

/// Whether a PR's change reached the environments of a service that
/// PostHog/charts deploys. nil means the deploy may still finish.
public enum ServiceDeployVerdict: Equatable, Sendable {
  case deployed
  /// The deploy can't finish as named, for the reason given.
  case stuck(String)

  /// `state` is the parsed state file, or nil when PostHog/charts has no
  /// state file for `service`. `progress` holds each environment that the
  /// poller could decide. A missing entry keeps the deploy open.
  public static func of(
    service: String, _ state: ServiceDeployState?, pr: SwitchboardCore.PullRequest,
    environments: [DeployEnvironment], progress: [DeployEnvironment: EnvironmentDeploy]
  ) -> ServiceDeployVerdict? {
    guard let state else { return .stuck("\(Wait.chartsRepository) has no state/\(service).yaml") }
    if let repository = state.repository, !Dependencies.sameRepo(repository, pr.repo) {
      return .stuck("\(service) deploys from \(repository), not \(pr.repo)")
    }
    if let failed = environments.first(where: { progress[$0]?.state == .failed }) {
      return .stuck("the deploy to \(failed.rawValue) failed" + (progress[failed]?.run.map { ": \($0)" } ?? ""))
    }
    if environments.contains(where: { progress[$0]?.state == .offBranch }) {
      return .stuck("it merged into \(pr.base), which \(service) doesn't deploy from")
    }
    return environments.allSatisfy({ progress[$0]?.state == .deployed }) ? .deployed : nil
  }
}
