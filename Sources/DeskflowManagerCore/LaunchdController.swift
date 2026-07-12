import Foundation

internal struct LaunchJobState {
  let loaded: Bool
  let state: ServiceProcessState
  let pid: Int32?
}

internal final class LaunchdController {
  private let runner: FixedProcessRunner

  init(runner: FixedProcessRunner) {
    self.runner = runner
  }

  func hasGUISession(uid: UInt32) -> Bool {
    (try? hasGUISessionRequired(uid: uid)) == true
  }

  func hasGUISessionRequired(uid: UInt32) throws -> Bool {
    let result = try runner.run(
      .launchctl,
      arguments: ["print", "gui/\(uid)"],
      timeout: 5
    )
    if result.terminationStatus == 0, !result.timedOut { return true }
    if result.terminationStatus == 112,
      result.stderr.contains("Could not find domain for user gui:")
    {
      return false
    }
    throw failure("Could not inspect the GUI session for uid \(uid)", result)
  }

  func job(uid: UInt32) -> LaunchJobState {
    (try? jobRequired(uid: uid))
      ?? LaunchJobState(loaded: false, state: .unknown, pid: nil)
  }

  func jobRequired(uid: UInt32) throws -> LaunchJobState {
    let result = try runner.run(
      .launchctl,
      arguments: ["print", serviceTarget(uid: uid)],
      timeout: 5
    )
    if result.terminationStatus == 113,
      result.stderr.contains("Could not find service")
    {
      return LaunchJobState(loaded: false, state: .notLoaded, pid: nil)
    }
    if result.terminationStatus == 112,
      result.stderr.contains("Could not find domain for user gui:")
    {
      return LaunchJobState(loaded: false, state: .notLoaded, pid: nil)
    }
    guard result.terminationStatus == 0, !result.timedOut else {
      throw failure("Could not inspect the supervisor for uid \(uid)", result)
    }

    var state: ServiceProcessState = .loaded
    var pid: Int32?
    for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
      let value = line.trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("state = ") {
        state = value.dropFirst("state = ".count) == "running" ? .running : .loaded
      } else if value.hasPrefix("pid = ") {
        pid = Int32(value.dropFirst("pid = ".count))
      }
    }
    return LaunchJobState(loaded: true, state: state, pid: pid)
  }

  func bootoutIfLoaded(uid: UInt32) throws {
    guard try jobRequired(uid: uid).loaded else { return }
    let result = try runner.run(
      .launchctl,
      arguments: ["bootout", serviceTarget(uid: uid)],
      timeout: 10
    )
    guard result.terminationStatus == 0, !result.timedOut else {
      throw failure("Could not stop the supervisor for uid \(uid)", result)
    }
  }

  @discardableResult
  func bootstrapIfLoggedIn(_ account: LocalAccount) throws -> Bool {
    guard try hasGUISessionRequired(uid: account.uid) else { return false }
    let target = serviceTarget(uid: account.uid)
    let enable = try runner.run(
      .launchctl,
      arguments: ["enable", target],
      timeout: 5
    )
    guard enable.terminationStatus == 0, !enable.timedOut else {
      throw failure("Could not enable the supervisor for \(account.name)", enable)
    }

    if try !jobRequired(uid: account.uid).loaded {
      let bootstrap = try runner.run(
        .launchctl,
        arguments: ["bootstrap", "gui/\(account.uid)", AgentPlistStore.plistPath(for: account)],
        timeout: 10
      )
      guard bootstrap.terminationStatus == 0, !bootstrap.timedOut else {
        throw failure("Could not bootstrap the supervisor for \(account.name)", bootstrap)
      }
      guard try jobRequired(uid: account.uid).loaded else {
        throw ManagerBackendError.processFailed(
          "The supervisor did not remain loaded for \(account.name)."
        )
      }
    }
    return true
  }

  func restart(_ account: LocalAccount) throws -> Bool {
    guard try hasGUISessionRequired(uid: account.uid) else { return false }
    if try !jobRequired(uid: account.uid).loaded {
      return try bootstrapIfLoggedIn(account)
    }
    let result = try runner.run(
      .launchctl,
      arguments: ["kickstart", "-k", serviceTarget(uid: account.uid)],
      timeout: 10
    )
    guard result.terminationStatus == 0, !result.timedOut else {
      throw failure("Could not restart the supervisor for \(account.name)", result)
    }
    guard try jobRequired(uid: account.uid).loaded else {
      throw ManagerBackendError.processFailed(
        "The supervisor did not remain loaded for \(account.name)."
      )
    }
    return true
  }

  private func serviceTarget(uid: UInt32) -> String {
    "gui/\(uid)/\(ManagerConstants.supervisorLabel)"
  }

  private func failure(_ prefix: String, _ result: ProcessResult) -> ManagerBackendError {
    let diagnostic = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).managerBounded
    return .processFailed(diagnostic.isEmpty ? prefix : "\(prefix): \(diagnostic)")
  }
}
