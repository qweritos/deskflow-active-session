import Darwin
import Foundation

public final class DeskflowManagerBackend: @unchecked Sendable {
  private let runner: FixedProcessRunner
  private let discovery: LocalAccountDiscovery
  private let launchd: LaunchdController
  private let supervisorPayload: Data
  private let supervisorDesignatedRequirement: String

  public init(
    supervisorPayload: Data,
    supervisorDesignatedRequirement: String,
    runner: FixedProcessRunner = FixedProcessRunner()
  ) {
    self.supervisorPayload = supervisorPayload
    self.supervisorDesignatedRequirement = supervisorDesignatedRequirement
    self.runner = runner
    discovery = LocalAccountDiscovery(runner: runner)
    launchd = LaunchdController(runner: runner)
  }

  public func snapshot() throws -> SystemSnapshot {
    try SystemSnapshotProvider(runner: runner).snapshot()
  }

  public func perform(_ request: OperationRequest) throws -> OperationResponse {
    guard request.schemaVersion == ManagerConstants.schemaVersion else {
      throw ManagerBackendError.invalidRequest("Unsupported manager request schema.")
    }
    guard
      !request.userIDs.isEmpty,
      request.userIDs.count <= ManagerConstants.maximumSelectedUsers
    else {
      throw ManagerBackendError.invalidRequest(
        "Select between one and \(ManagerConstants.maximumSelectedUsers) local accounts."
      )
    }
    let uniqueIDs = Array(Set(request.userIDs)).sorted()
    guard uniqueIDs.count == request.userIDs.count else {
      throw ManagerBackendError.invalidRequest("Duplicate account identifiers are not allowed.")
    }

    let lock = try RootOperationLock()
    defer { withExtendedLifetime(lock) {} }
    let allAccounts = try discovery.accounts()
    let byUID = Dictionary(uniqueKeysWithValues: allAccounts.map { ($0.uid, $0) })
    let selected = try uniqueIDs.map { uid -> LocalAccount in
      guard let account = byUID[uid] else { throw ManagerBackendError.accountNotFound(uid) }
      return account
    }

    switch request.operation {
    case .install:
      return try install(selected: selected, allAccounts: allAccounts)
    case .restart:
      return try restart(selected: selected)
    case .uninstall:
      return try uninstall(selected: selected, allAccounts: allAccounts)
    }
  }

  private func install(
    selected: [LocalAccount],
    allAccounts: [LocalAccount]
  ) throws -> OperationResponse {
    guard FileManager.default.isExecutableFile(atPath: ManagerConstants.deskflowCorePath) else {
      throw ManagerBackendError.invalidPayload(
        "Deskflow CLI core is not installed at the expected path.")
    }
    guard !supervisorPayload.isEmpty, supervisorPayload.count <= 64 * 1_024 * 1_024 else {
      throw ManagerBackendError.invalidPayload("Supervisor payload has an invalid size.")
    }

    var selectedBackups: [UInt32: Data?] = [:]
    for account in selected {
      let state = try AgentPlistStore.inspect(account)
      if !account.isEligible, !state.isManaged {
        throw ManagerBackendError.accountIneligible(
          "\(account.name) is not an eligible GUI account: \(account.exclusionReason ?? "excluded")"
        )
      }
      if case .invalid(_, _, let reason) = state {
        throw ManagerBackendError.invalidLaunchAgent(
          "Refusing to replace \(account.name)'s unexpected LaunchAgent: \(reason)"
        )
      }
      selectedBackups[account.uid] = state.data
      _ = try AgentPlistStore.render(for: account)
    }

    var installedAccounts: [LocalAccount] = []
    for account in allAccounts {
      let state: AgentPlistState
      do {
        state = try AgentPlistStore.inspect(account)
      } catch {
        if selected.contains(where: { $0.uid == account.uid }) { throw error }
        if try launchd.jobRequired(uid: account.uid).loaded {
          throw ManagerBackendError.invalidLaunchAgent(
            "The supervisor is loaded for \(account.name), but its LaunchAgent cannot be safely inspected."
          )
        }
        // An unselected account with an unsafe or unavailable home remains
        // visible as unknown, but cannot safely participate in this upgrade.
        continue
      }
      if state.isValid { installedAccounts.append(account) }
      if state.isManaged, !state.isValid, !selected.contains(where: { $0.uid == account.uid }) {
        throw ManagerBackendError.invalidLaunchAgent(
          "Refusing shared upgrade while \(account.name) has an invalid managed LaunchAgent."
        )
      }
    }
    let affected = uniqueAccounts(installedAccounts + selected)

    let supervisorURL = URL(fileURLWithPath: ManagerConstants.supervisorPath)
    let binaryDirectory = try supervisorDirectory(create: true)
    let binaryName = supervisorURL.lastPathComponent
    let oldBinary = try binaryDirectory.readRegularFile(
      binaryName,
      maximumBytes: 64 * 1_024 * 1_024,
      expectedOwner: 0,
      requireOwnerOnlyWrite: true
    )
    if oldBinary != nil {
      try CodeSignatureValidator.validateExistingSupervisor(at: supervisorURL)
    }

    var stoppedAccounts: [LocalAccount] = []
    do {
      for account in affected where try launchd.jobRequired(uid: account.uid).loaded {
        try launchd.bootoutIfLoaded(uid: account.uid)
        stoppedAccounts.append(account)
      }

      try binaryDirectory.atomicWrite(
        supervisorPayload,
        named: binaryName,
        owner: 0,
        group: 0,
        mode: 0o755
      )
      let installedPayload = try binaryDirectory.readRegularFile(
        binaryName,
        maximumBytes: 64 * 1_024 * 1_024,
        expectedOwner: 0,
        requireOwnerOnlyWrite: true
      )
      guard installedPayload == supervisorPayload else {
        throw ManagerBackendError.invalidPayload(
          "Installed supervisor bytes do not match the sealed application payload."
        )
      }
      try CodeSignatureValidator.validateSupervisor(
        at: supervisorURL,
        designatedRequirement: supervisorDesignatedRequirement
      )

      for account in selected {
        try AgentPlistStore.install(account, data: try AgentPlistStore.render(for: account))
      }
      for account in affected {
        let state = try AgentPlistStore.inspect(account)
        guard state.isValid else {
          throw ManagerBackendError.invalidLaunchAgent(
            "LaunchAgent validation failed for \(account.name) after installation."
          )
        }
        _ = try launchd.restart(account)
      }
    } catch {
      let operationError = error
      var rollbackFailures: [String] = []
      for account in affected {
        do {
          try launchd.bootoutIfLoaded(uid: account.uid)
        } catch {
          rollbackFailures.append("stop \(account.name): \(errorMessage(error))")
        }
      }
      do {
        try restoreBinary(
          oldBinary,
          directory: binaryDirectory,
          name: binaryName,
          payload: supervisorPayload
        )
      } catch {
        rollbackFailures.append("restore shared supervisor: \(errorMessage(error))")
      }
      for account in selected {
        do {
          if let previous = selectedBackups[account.uid] ?? nil {
            try AgentPlistStore.install(account, data: previous)
          } else {
            let current = try AgentPlistStore.inspect(account)
            if current.isManaged {
              guard current.isValid, let currentData = current.data else {
                throw ManagerBackendError.invalidLaunchAgent(
                  "The newly written LaunchAgent is no longer canonical."
                )
              }
              _ = try AgentPlistStore.remove(account, expectedData: currentData)
            }
          }
        } catch {
          rollbackFailures.append("restore \(account.name): \(errorMessage(error))")
        }
      }
      for account in uniqueAccounts(stoppedAccounts + installedAccounts) {
        do {
          if try AgentPlistStore.inspect(account).isValid {
            _ = try launchd.restart(account)
          }
        } catch {
          rollbackFailures.append("restart \(account.name): \(errorMessage(error))")
        }
      }
      guard rollbackFailures.isEmpty else {
        throw ManagerBackendError.processFailed(
          "\(errorMessage(operationError)) Rollback incomplete: "
            + rollbackFailures.joined(separator: "; ").managerBounded
        )
      }
      throw operationError
    }

    let results = selected.map { account in
      UserOperationResult(
        uid: account.uid,
        userName: account.name,
        succeeded: true,
        message: launchd.hasGUISession(uid: account.uid)
          ? "Installed and running in the GUI session."
          : "Installed; starts at the next GUI login."
      )
    }
    return OperationResponse(
      operation: .install,
      results: results,
      summary:
        "Installed for \(results.count) account(s); restarted \(affected.count) managed supervisor(s)."
    )
  }

  private func restart(selected: [LocalAccount]) throws -> OperationResponse {
    var results: [UserOperationResult] = []
    for account in selected {
      do {
        let state = try AgentPlistStore.inspect(account)
        guard state.isValid else {
          throw ManagerBackendError.invalidLaunchAgent(
            "A valid managed LaunchAgent is not installed.")
        }
        let started = try launchd.restart(account)
        results.append(
          UserOperationResult(
            uid: account.uid,
            userName: account.name,
            succeeded: true,
            message: started ? "Supervisor restarted." : "Account is logged out; start is deferred."
          )
        )
      } catch {
        let operationError = error
        do {
          if try AgentPlistStore.inspect(account).isValid {
            _ = try launchd.restart(account)
          }
          results.append(failureResult(account, error: operationError))
        } catch {
          results.append(
            failureResult(
              account,
              error: ManagerBackendError.processFailed(
                "\(errorMessage(operationError)) Recovery failed: \(errorMessage(error))"
              )
            )
          )
        }
      }
    }
    return OperationResponse(
      operation: .restart,
      results: results,
      summary: summary("restart", results: results)
    )
  }

  private func uninstall(
    selected: [LocalAccount],
    allAccounts: [LocalAccount]
  ) throws -> OperationResponse {
    var validated: [(LocalAccount, Data)] = []
    for account in selected {
      let state = try AgentPlistStore.inspect(account)
      guard state.isValid, let data = state.data else {
        throw ManagerBackendError.invalidLaunchAgent(
          "Refusing to remove an absent or unexpected LaunchAgent for \(account.name)."
        )
      }
      validated.append((account, data))
    }

    let selectedIDs = Set(selected.map(\.uid))
    var remainingManaged = false
    var inventoryUncertain = false
    for account in allAccounts where !selectedIDs.contains(account.uid) {
      do {
        if try AgentPlistStore.inspect(account).isManaged {
          remainingManaged = true
        }
      } catch {
        inventoryUncertain = true
      }
    }

    var results: [UserOperationResult] = []
    for (account, expectedData) in validated {
      do {
        try launchd.bootoutIfLoaded(uid: account.uid)
        guard try AgentPlistStore.remove(account, expectedData: expectedData) else {
          throw ManagerBackendError.invalidLaunchAgent(
            "The managed LaunchAgent disappeared before it could be removed."
          )
        }
        try launchd.bootoutIfLoaded(uid: account.uid)
        guard try !launchd.jobRequired(uid: account.uid).loaded else {
          throw ManagerBackendError.processFailed(
            "The supervisor remained loaded for \(account.name) after uninstall."
          )
        }
        results.append(
          UserOperationResult(
            uid: account.uid,
            userName: account.name,
            succeeded: true,
            message: "LaunchAgent removed."
          )
        )
      } catch {
        let operationError = error
        do {
          if try AgentPlistStore.inspect(account).isValid {
            _ = try launchd.restart(account)
          }
          results.append(failureResult(account, error: operationError))
        } catch {
          results.append(
            failureResult(
              account,
              error: ManagerBackendError.processFailed(
                "\(errorMessage(operationError)) Recovery failed: \(errorMessage(error))"
              )
            )
          )
        }
      }
    }

    var sharedMessage: String
    if !results.allSatisfy(\.succeeded) {
      sharedMessage = "Shared supervisor retained because an uninstall did not complete."
    } else if inventoryUncertain {
      sharedMessage =
        "Shared supervisor retained because another account could not be safely inspected."
    } else {
      sharedMessage = "Shared supervisor retained because another managed agent remains."
    }
    if !remainingManaged, !inventoryUncertain, results.allSatisfy(\.succeeded) {
      let supervisorURL = URL(fileURLWithPath: ManagerConstants.supervisorPath)
      let directory = try supervisorDirectory(create: false)
      if let data = try directory.readRegularFile(
        supervisorURL.lastPathComponent,
        maximumBytes: 64 * 1_024 * 1_024,
        expectedOwner: 0,
        requireOwnerOnlyWrite: true
      ) {
        do {
          try CodeSignatureValidator.validateExistingSupervisor(at: supervisorURL)
          _ = try directory.removeRegularFile(
            supervisorURL.lastPathComponent,
            expectedData: data,
            expectedOwner: 0,
            requireOwnerOnlyWrite: true
          )
          sharedMessage = "Shared supervisor removed because no managed agents remain."
        } catch {
          throw ManagerBackendError.processFailed(
            "Selected LaunchAgents were removed, but the shared supervisor could not be removed: "
              + errorMessage(error)
          )
        }
      } else {
        sharedMessage = "No shared supervisor remained to remove."
      }
    }

    return OperationResponse(
      operation: .uninstall,
      results: results,
      summary: "\(summary("uninstall", results: results)) \(sharedMessage)"
    )
  }

  private func restoreBinary(
    _ oldBinary: Data?,
    directory: SecureDirectory,
    name: String,
    payload: Data
  ) throws {
    if let oldBinary {
      try directory.atomicWrite(oldBinary, named: name, owner: 0, group: 0, mode: 0o755)
    } else {
      _ = try directory.removeRegularFile(
        name,
        expectedData: payload,
        expectedOwner: 0,
        requireOwnerOnlyWrite: true
      )
    }
  }

  private func supervisorDirectory(create: Bool) throws -> SecureDirectory {
    let directoryURL = URL(fileURLWithPath: ManagerConstants.supervisorPath)
      .deletingLastPathComponent()
    guard directoryURL.path == "/usr/local/libexec" else {
      throw ManagerBackendError.unsafeFileSystem(
        "Supervisor installation directory is not allowlisted."
      )
    }
    let usr = try SecureDirectory.openAbsolute("/usr", finalOwner: 0)
    guard
      let local = try usr.childDirectory(
        "local",
        create: create,
        owner: 0,
        group: 0,
        mode: 0o755
      ),
      let directory = try local.childDirectory(
        "libexec",
        create: create,
        owner: 0,
        group: 0,
        mode: 0o755
      )
    else {
      throw ManagerBackendError.unsafeFileSystem(
        "Supervisor installation directory is missing."
      )
    }
    return directory
  }

  private func uniqueAccounts(_ accounts: [LocalAccount]) -> [LocalAccount] {
    var seen = Set<UInt32>()
    return accounts.filter { seen.insert($0.uid).inserted }.sorted { $0.uid < $1.uid }
  }

  private func failureResult(_ account: LocalAccount, error: Error) -> UserOperationResult {
    return UserOperationResult(
      uid: account.uid,
      userName: account.name,
      succeeded: false,
      message: errorMessage(error)
    )
  }

  private func errorMessage(_ error: Error) -> String {
    ((error as? LocalizedError)?.errorDescription ?? String(describing: error)).managerBounded
  }

  private func summary(_ verb: String, results: [UserOperationResult]) -> String {
    let succeeded = results.filter(\.succeeded).count
    return "\(verb.capitalized): \(succeeded) succeeded, \(results.count - succeeded) failed."
  }
}
