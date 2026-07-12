import Darwin
import Foundation

public final class SystemSnapshotProvider: @unchecked Sendable {
  private let runner: FixedProcessRunner
  private let discovery: LocalAccountDiscovery
  private let launchd: LaunchdController

  public init(runner: FixedProcessRunner = FixedProcessRunner()) {
    self.runner = runner
    discovery = LocalAccountDiscovery(runner: runner)
    launchd = LaunchdController(runner: runner)
  }

  public func snapshot() throws -> SystemSnapshot {
    let accounts = try discovery.accounts()
    let consoleOwner =
      try? FileManager.default.attributesOfItem(atPath: "/dev/console")[
        .ownerAccountName
      ] as? String
    let activeUser: String?
    if let consoleOwner, consoleOwner != "root", consoleOwner != "loginwindow" {
      activeUser = consoleOwner
    } else {
      activeUser = nil
    }
    let processRows = try processes()

    var statuses: [UserStatus] = []
    for account in accounts {
      let inspection: AgentPlistState
      do {
        inspection = try AgentPlistStore.inspect(account)
      } catch {
        statuses.append(
          UserStatus(
            account: account,
            isInstalled: false,
            hasGUISession: launchd.hasGUISession(uid: account.uid),
            supervisorState: .unknown,
            supervisorPID: nil,
            serverPIDs: [],
            expectedServerRunning: false,
            health: .needsAttention,
            detail: (error as? LocalizedError)?.errorDescription?.managerBounded
              ?? "Could not inspect the LaunchAgent."
          )
        )
        continue
      }

      let gui = launchd.hasGUISession(uid: account.uid)
      let job = launchd.job(uid: account.uid)
      let servers: [Int32]
      if let supervisorPID = job.pid {
        servers = processRows.compactMap { row in
          row.parentPID == supervisorPID
            && row.uid == account.uid
            && row.command == ManagerConstants.deskflowCorePath
            ? row.pid : nil
        }.sorted()
      } else {
        servers = []
      }
      let expected = inspection.isValid && activeUser == account.name
      let healthAndDetail = health(
        inspection: inspection,
        gui: gui,
        job: job,
        serverPIDs: servers,
        expected: expected
      )
      statuses.append(
        UserStatus(
          account: account,
          isInstalled: inspection.isManaged,
          hasGUISession: gui,
          supervisorState: job.state,
          supervisorPID: job.pid,
          serverPIDs: servers,
          expectedServerRunning: expected,
          health: healthAndDetail.0,
          detail: healthAndDetail.1
        )
      )
    }

    return SystemSnapshot(
      activeUserName: activeUser,
      deskflowCoreAvailable: FileManager.default.isExecutableFile(
        atPath: ManagerConstants.deskflowCorePath
      ),
      // Status collection never executes an installed root-owned payload.
      installedSupervisorVersion: nil,
      users: statuses,
      portListeners: try portListeners()
    )
  }

  private struct ProcessRow {
    let pid: Int32
    let parentPID: Int32
    let uid: UInt32
    let command: String
  }

  private func processes() throws -> [ProcessRow] {
    let result = try runner.run(
      .ps,
      arguments: ["-axo", "pid=,ppid=,uid=,comm="],
      timeout: 10
    )
    guard result.terminationStatus == 0, !result.timedOut else {
      throw ManagerBackendError.processFailed("Could not inspect running processes.")
    }
    return result.stdout.split(separator: "\n").compactMap { line in
      let fields = line.split(maxSplits: 3, whereSeparator: { $0.isWhitespace })
      guard fields.count == 4,
        let pid = Int32(fields[0]),
        let parentPID = Int32(fields[1]),
        let uid = UInt32(fields[2])
      else { return nil }
      return ProcessRow(
        pid: pid,
        parentPID: parentPID,
        uid: uid,
        command: String(fields[3]).trimmingCharacters(in: .whitespaces)
      )
    }
  }

  private func portListeners() throws -> [PortListener] {
    let result = try runner.run(
      .lsof,
      arguments: ["-nP", "-iTCP:24800", "-sTCP:LISTEN", "-Fpcu"],
      timeout: 10
    )
    if result.terminationStatus == 1, result.stdout.isEmpty { return [] }
    guard result.terminationStatus == 0, !result.timedOut else {
      throw ManagerBackendError.processFailed("Could not inspect TCP 24800 listeners.")
    }

    var listeners: [PortListener] = []
    var pid: Int32?
    var uid: UInt32?
    var command = ""
    func appendCurrent() {
      if let pid, let uid {
        listeners.append(PortListener(pid: pid, uid: uid, command: String(command.prefix(256))))
      }
    }
    for line in result.stdout.split(separator: "\n") {
      guard let marker = line.first else { continue }
      let value = line.dropFirst()
      switch marker {
      case "p":
        appendCurrent()
        pid = Int32(value)
        uid = nil
        command = ""
      case "u": uid = UInt32(value)
      case "c": command = String(value)
      default: break
      }
    }
    appendCurrent()
    return listeners.sorted { ($0.pid, $0.uid) < ($1.pid, $1.uid) }
  }

  private func health(
    inspection: AgentPlistState,
    gui: Bool,
    job: LaunchJobState,
    serverPIDs: [Int32],
    expected: Bool
  ) -> (UserHealth, String) {
    if !inspection.isManaged { return (.notInstalled, "Not installed") }
    if !inspection.isValid {
      return (.needsAttention, inspection.detail?.managerBounded ?? "LaunchAgent is invalid")
    }
    if job.state == .unknown {
      return (.unknown, "Could not determine the supervisor launchd state")
    }
    if !gui { return (.loggedOut, "Installed; starts at next GUI login") }
    if expected, !serverPIDs.isEmpty { return (.active, "Active server is running") }
    if expected, job.state == .running { return (.starting, "Waiting for the server to start") }
    if expected { return (.needsAttention, "Active user's supervisor is not running") }
    if !serverPIDs.isEmpty { return (.stopping, "Inactive user's server is still stopping") }
    if job.state == .running {
      return (.standby, "Supervisor is waiting in the background session")
    }
    return (.needsAttention, "Supervisor is not running in this GUI session")
  }
}
