import Darwin
import Foundation
import XCTest

@testable import DeskflowManagerCore

final class BackendSafetyTests: XCTestCase {
  private let account = LocalAccount(
    uid: 501,
    gid: 20,
    name: "alice",
    displayName: "Alice",
    homeDirectory: "/Users/alice",
    shell: "/bin/zsh",
    isEligible: true,
    exclusionReason: nil
  )

  func testRenderedAgentUsesOnlyStandardPaths() throws {
    let data = try AgentPlistStore.render(for: account)
    let object = try PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    )
    let plist = try XCTUnwrap(object as? [String: Any])

    XCTAssertEqual(
      plist["Label"] as? String,
      ManagerConstants.supervisorLabel
    )
    XCTAssertEqual(
      plist["ProgramArguments"] as? [String],
      [
        ManagerConstants.supervisorPath,
        "--core",
        ManagerConstants.deskflowCorePath,
      ]
    )
    XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
    XCTAssertEqual(plist["KeepAlive"] as? Bool, true)

    guard
      case .valid = AgentPlistStore.validate(
        data,
        homeDirectory: account.homeDirectory,
        userName: account.name
      )
    else {
      return XCTFail("Rendered plist did not pass canonical validation")
    }
  }

  func testAgentValidationRejectsUnexpectedTopLevelKey() throws {
    var plist = try renderedPlistDictionary()
    plist["EnvironmentVariables"] = ["PATH": "/tmp"]
    let state = AgentPlistStore.validate(
      try plistData(plist),
      homeDirectory: account.homeDirectory,
      userName: account.name
    )

    guard case .invalid(_, let managed, let reason) = state else {
      return XCTFail("Plist with an unexpected key was accepted")
    }
    XCTAssertTrue(managed)
    XCTAssertTrue(reason.contains("unexpected keys"))
  }

  func testAgentValidationRequiresCanonicalKeySet() throws {
    var plist = try renderedPlistDictionary()
    plist.removeValue(forKey: "StandardErrorPath")
    let state = AgentPlistStore.validate(
      try plistData(plist),
      homeDirectory: account.homeDirectory,
      userName: account.name
    )

    guard case .invalid(_, let managed, _) = state else {
      return XCTFail("Plist with a missing canonical key was accepted")
    }
    XCTAssertTrue(managed)
  }

  func testLegacyAgentSchemaRemainsCanonical() throws {
    var plist = try renderedPlistDictionary()
    plist["ProgramArguments"] = [ManagerConstants.supervisorPath]
    plist.removeValue(forKey: "ExitTimeOut")
    let state = AgentPlistStore.validate(
      try plistData(plist),
      homeDirectory: account.homeDirectory,
      userName: account.name
    )

    guard case .valid = state else {
      return XCTFail("Known legacy LaunchAgent schema was rejected")
    }
  }

  func testQuarantineRemovalRestoresFileWhenContentDoesNotMatch() throws {
    try withSecureTestDirectory { directory in
      let original = Data("original".utf8)
      try directory.atomicWrite(
        original,
        named: "managed.plist",
        owner: geteuid(),
        group: getegid(),
        mode: 0o600
      )

      XCTAssertThrowsError(
        try directory.removeRegularFile(
          "managed.plist",
          expectedData: Data("different".utf8),
          expectedOwner: geteuid(),
          requireOwnerOnlyWrite: true
        )
      )
      XCTAssertEqual(
        try directory.readRegularFile(
          "managed.plist",
          maximumBytes: 1_024,
          expectedOwner: geteuid(),
          requireOwnerOnlyWrite: true
        ),
        original
      )
    }
  }

  func testQuarantineRemovalDoesNotFollowSymlink() throws {
    try withSecureTestDirectory { directory in
      let targetURL = URL(fileURLWithPath: directory.path)
        .appendingPathComponent("target")
      let linkURL = URL(fileURLWithPath: directory.path)
        .appendingPathComponent("managed.plist")
      try Data("target".utf8).write(to: targetURL)
      try FileManager.default.createSymbolicLink(
        at: linkURL,
        withDestinationURL: targetURL
      )

      XCTAssertThrowsError(
        try directory.removeRegularFile(
          "managed.plist",
          expectedData: Data("target".utf8),
          expectedOwner: geteuid(),
          requireOwnerOnlyWrite: true
        )
      )
      XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), targetURL.path)
    }
  }

  func testExtendedACLIsRejected() throws {
    try withSecureTestDirectory { directory in
      try directory.atomicWrite(
        Data("acl".utf8),
        named: "acl-test",
        owner: geteuid(),
        group: getegid(),
        mode: 0o600
      )
      let filePath = directory.path + "/acl-test"
      let chmod = Process()
      chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
      chmod.arguments = ["+a", "everyone deny delete", filePath]
      chmod.standardOutput = FileHandle.nullDevice
      chmod.standardError = FileHandle.nullDevice
      try chmod.run()
      chmod.waitUntilExit()
      guard chmod.terminationStatus == 0 else {
        throw XCTSkip("Test filesystem does not support extended ACLs")
      }
      defer {
        let clear = Process()
        clear.executableURL = URL(fileURLWithPath: "/bin/chmod")
        clear.arguments = ["-N", filePath]
        try? clear.run()
        clear.waitUntilExit()
      }

      let descriptor = Darwin.open(filePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      XCTAssertGreaterThanOrEqual(descriptor, 0)
      defer { if descriptor >= 0 { Darwin.close(descriptor) } }
      XCTAssertThrowsError(
        try SecureDirectory.rejectNonEmptyExtendedACL(
          on: descriptor,
          description: filePath
        )
      )
    }
  }

  func testDuplicateUserIDsAreRejectedBeforeMutation() throws {
    let backend = DeskflowManagerBackend(
      supervisorPayload: Data([0x00]),
      supervisorDesignatedRequirement: "identifier \"invalid\""
    )
    let request = OperationRequest(
      operation: .install,
      userIDs: [501, 501]
    )

    XCTAssertThrowsError(try backend.perform(request)) { error in
      guard case ManagerBackendError.invalidRequest = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testTooManyUserIDsAreRejectedBeforeMutation() throws {
    let backend = DeskflowManagerBackend(
      supervisorPayload: Data([0x00]),
      supervisorDesignatedRequirement: "identifier \"invalid\""
    )
    let request = OperationRequest(
      operation: .install,
      userIDs: (0...ManagerConstants.maximumSelectedUsers).map {
        UInt32(500 + $0)
      }
    )

    XCTAssertThrowsError(try backend.perform(request)) { error in
      guard case ManagerBackendError.invalidRequest = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testProcessRunnerUsesAllowlistedExecutable() throws {
    let result = try FixedProcessRunner(maximumOutputBytes: 1_024).run(
      .ps,
      arguments: ["-p", "\(getpid())", "-o", "pid="],
      timeout: 5
    )

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertFalse(result.timedOut)
    XCTAssertEqual(
      result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
      "\(getpid())"
    )
  }

  func testProcessRunnerRejectsInvalidTimeout() {
    XCTAssertThrowsError(
      try FixedProcessRunner().run(
        .ps,
        arguments: [],
        timeout: .infinity
      )
    )
  }

  func testSupervisorValidatorRejectsUnrelatedExecutable() {
    XCTAssertThrowsError(
      try CodeSignatureValidator.validateSupervisor(
        at: URL(fileURLWithPath: "/usr/bin/true")
      )
    )
  }

  func testRootOperationLockRejectsUnprivilegedCaller() throws {
    guard geteuid() != 0 else { throw XCTSkip("Test process is root") }
    XCTAssertThrowsError(try RootOperationLock()) { error in
      guard case ManagerBackendError.permissionDenied = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  private func renderedPlistDictionary() throws -> [String: Any] {
    let object = try PropertyListSerialization.propertyList(
      from: AgentPlistStore.render(for: account),
      options: [],
      format: nil
    )
    return try XCTUnwrap(object as? [String: Any])
  }

  private func plistData(_ plist: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
  }

  private func withSecureTestDirectory(
    _ body: (SecureDirectory) throws -> Void
  ) throws {
    let homeURL = FileManager.default.homeDirectoryForCurrentUser
    let home = try SecureDirectory.openAbsolute(homeURL.path, finalOwner: geteuid())
    let name = ".deskflow-manager-test-\(UUID().uuidString)"
    let testURL = homeURL.appendingPathComponent(name, isDirectory: true)
    guard
      let directory = try home.childDirectory(
        name,
        create: true,
        owner: geteuid(),
        group: getegid(),
        mode: 0o700
      )
    else {
      return XCTFail("Could not create secure test directory")
    }
    defer { try? FileManager.default.removeItem(at: testURL) }
    try body(directory)
  }
}
