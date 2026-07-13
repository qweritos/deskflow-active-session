import Foundation

public enum ManagerConstants {
  public static let schemaVersion = 1
  public static let managerVersion = "0.2.2"
  public static let maximumSelectedUsers = 64
  public static let appBundleIdentifier =
    "io.github.qweritos.deskflow-active-session.manager"
  public static let helperLabel =
    "io.github.qweritos.deskflow-active-session.manager-helper"
  public static let helperPlistName = "\(helperLabel).plist"
  public static let supervisorLabel = "com.local.deskflow.active-session"
  public static let supervisorIdentifier =
    "io.github.qweritos.deskflow-active-session.supervisor"
  public static let supervisorPath =
    "/usr/local/libexec/deskflow-session-supervisor"
  public static let deskflowCorePath =
    "/Applications/Deskflow.app/Contents/MacOS/deskflow-core"
  public static let stateDirectory =
    "/Library/Application Support/io.github.qweritos.deskflow-active-session/state"

  public static let supervisorResourceName = "deskflow-session-supervisor"
  public static let helperExecutableName = "deskflow-manager-helper"
  public static let managerExecutableName = "Deskflow Active Session Manager"
  public static let managerAppName = "Deskflow ASM.app"
  public static let managerAppPath = "/Applications/\(managerAppName)"
}

public struct LocalAccount: Codable, Hashable, Identifiable, Sendable {
  public let uid: UInt32
  public let gid: UInt32
  public let name: String
  public let displayName: String
  public let homeDirectory: String
  public let shell: String
  public let isEligible: Bool
  public let exclusionReason: String?

  public var id: UInt32 { uid }

  public init(
    uid: UInt32,
    gid: UInt32,
    name: String,
    displayName: String,
    homeDirectory: String,
    shell: String,
    isEligible: Bool,
    exclusionReason: String?
  ) {
    self.uid = uid
    self.gid = gid
    self.name = name
    self.displayName = displayName
    self.homeDirectory = homeDirectory
    self.shell = shell
    self.isEligible = isEligible
    self.exclusionReason = exclusionReason
  }
}

public enum ServiceProcessState: String, Codable, Sendable {
  case notLoaded
  case loaded
  case running
  case unknown
}

public enum UserHealth: String, Codable, Sendable {
  case notInstalled
  case loggedOut
  case active
  case standby
  case starting
  case stopping
  case needsAttention
  case unknown
}

public struct UserStatus: Codable, Hashable, Identifiable, Sendable {
  public let account: LocalAccount
  public let isInstalled: Bool
  public let hasGUISession: Bool
  public let supervisorState: ServiceProcessState
  public let supervisorPID: Int32?
  public let serverPIDs: [Int32]
  public let expectedServerRunning: Bool
  public let health: UserHealth
  public let detail: String

  public var id: UInt32 { account.uid }

  public init(
    account: LocalAccount,
    isInstalled: Bool,
    hasGUISession: Bool,
    supervisorState: ServiceProcessState,
    supervisorPID: Int32?,
    serverPIDs: [Int32],
    expectedServerRunning: Bool,
    health: UserHealth,
    detail: String
  ) {
    self.account = account
    self.isInstalled = isInstalled
    self.hasGUISession = hasGUISession
    self.supervisorState = supervisorState
    self.supervisorPID = supervisorPID
    self.serverPIDs = serverPIDs
    self.expectedServerRunning = expectedServerRunning
    self.health = health
    self.detail = detail
  }
}

public struct PortListener: Codable, Hashable, Sendable {
  public let pid: Int32
  public let uid: UInt32
  public let command: String

  public init(pid: Int32, uid: UInt32, command: String) {
    self.pid = pid
    self.uid = uid
    self.command = command
  }
}

public struct SystemSnapshot: Codable, Sendable {
  public let schemaVersion: Int
  public let capturedAt: Date
  public let activeUserName: String?
  public let deskflowCoreAvailable: Bool
  public let installedSupervisorVersion: String?
  public let users: [UserStatus]
  public let portListeners: [PortListener]

  public init(
    schemaVersion: Int = ManagerConstants.schemaVersion,
    capturedAt: Date = Date(),
    activeUserName: String?,
    deskflowCoreAvailable: Bool,
    installedSupervisorVersion: String?,
    users: [UserStatus],
    portListeners: [PortListener]
  ) {
    self.schemaVersion = schemaVersion
    self.capturedAt = capturedAt
    self.activeUserName = activeUserName
    self.deskflowCoreAvailable = deskflowCoreAvailable
    self.installedSupervisorVersion = installedSupervisorVersion
    self.users = users
    self.portListeners = portListeners
  }
}

public enum ManagerOperation: String, Codable, Sendable {
  case install
  case restart
  case uninstall
}

public struct OperationRequest: Codable, Sendable {
  public let schemaVersion: Int
  public let operation: ManagerOperation
  public let userIDs: [UInt32]

  public init(
    schemaVersion: Int = ManagerConstants.schemaVersion,
    operation: ManagerOperation,
    userIDs: [UInt32]
  ) {
    self.schemaVersion = schemaVersion
    self.operation = operation
    self.userIDs = userIDs
  }
}

public struct UserOperationResult: Codable, Hashable, Identifiable, Sendable {
  public let uid: UInt32
  public let userName: String
  public let succeeded: Bool
  public let message: String

  public var id: UInt32 { uid }

  public init(
    uid: UInt32,
    userName: String,
    succeeded: Bool,
    message: String
  ) {
    self.uid = uid
    self.userName = userName
    self.succeeded = succeeded
    self.message = message
  }
}

public struct OperationResponse: Codable, Sendable {
  public let schemaVersion: Int
  public let operation: ManagerOperation
  public let results: [UserOperationResult]
  public let summary: String

  public init(
    schemaVersion: Int = ManagerConstants.schemaVersion,
    operation: ManagerOperation,
    results: [UserOperationResult],
    summary: String
  ) {
    self.schemaVersion = schemaVersion
    self.operation = operation
    self.results = results
    self.summary = summary
  }
}

@objc public protocol DeskflowManagerXPCProtocol {
  func version(withReply reply: @escaping (String) -> Void)
  func snapshot(withReply reply: @escaping (Data?, String?) -> Void)
  func perform(
    _ request: Data,
    authorization: Data,
    withReply reply: @escaping (Data?, String?) -> Void
  )
}
