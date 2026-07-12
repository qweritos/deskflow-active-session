import XCTest

@testable import DeskflowManagerCore

final class ManagerModelsTests: XCTestCase {
  func testOperationRequestRoundTrip() throws {
    let request = OperationRequest(
      operation: .install,
      userIDs: [501, 503]
    )

    let data = try PropertyListEncoder().encode(request)
    let decoded = try PropertyListDecoder().decode(
      OperationRequest.self,
      from: data
    )

    XCTAssertEqual(decoded.schemaVersion, ManagerConstants.schemaVersion)
    XCTAssertEqual(decoded.operation, .install)
    XCTAssertEqual(decoded.userIDs, [501, 503])
  }

  func testSnapshotRoundTripPreservesUserIdentity() throws {
    let account = LocalAccount(
      uid: 501,
      gid: 20,
      name: "alice",
      displayName: "Alice",
      homeDirectory: "/Users/alice",
      shell: "/bin/zsh",
      isEligible: true,
      exclusionReason: nil
    )
    let status = UserStatus(
      account: account,
      isInstalled: true,
      hasGUISession: true,
      supervisorState: .running,
      supervisorPID: 42,
      serverPIDs: [43],
      expectedServerRunning: true,
      health: .active,
      detail: "Active and sharing"
    )
    let snapshot = SystemSnapshot(
      activeUserName: "alice",
      deskflowCoreAvailable: true,
      installedSupervisorVersion: "0.2.0",
      users: [status],
      portListeners: [PortListener(pid: 43, uid: 501, command: "deskflow-core")]
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(SystemSnapshot.self, from: data)

    XCTAssertEqual(decoded.users.first?.account.uid, 501)
    XCTAssertEqual(decoded.users.first?.health, .active)
    XCTAssertEqual(decoded.portListeners.first?.pid, 43)
  }
}
