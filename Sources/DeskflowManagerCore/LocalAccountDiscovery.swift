import Darwin
import Foundation

public final class LocalAccountDiscovery: @unchecked Sendable {
  private let runner: FixedProcessRunner

  public init(runner: FixedProcessRunner = FixedProcessRunner()) {
    self.runner = runner
  }

  public func accounts() throws -> [LocalAccount] {
    let result = try runner.run(
      .dscl,
      arguments: [
        "-plist", ".", "-readall", "/Users",
        "UniqueID", "PrimaryGroupID", "NFSHomeDirectory", "UserShell",
        "RealName", "RecordName", "IsHidden",
      ],
      timeout: 15
    )
    guard result.terminationStatus == 0, !result.timedOut else {
      throw ManagerBackendError.processFailed(
        "Could not enumerate local accounts: \(result.stderr.managerBounded)"
      )
    }

    let object = try PropertyListSerialization.propertyList(
      from: Data(result.stdout.utf8),
      options: [],
      format: nil
    )
    guard let records = object as? [[String: Any]] else {
      throw ManagerBackendError.processFailed(
        "Directory Services returned an unexpected account list.")
    }

    var resultAccounts: [LocalAccount] = []
    var seenUIDs = Set<UInt32>()
    for record in records {
      guard let uid = uint32(record, suffix: ":UniqueID"), uid >= 500,
        let gid = uint32(record, suffix: ":PrimaryGroupID"),
        let name = first(record, suffix: ":RecordName"),
        let home = first(record, suffix: ":NFSHomeDirectory"),
        !name.isEmpty, name.utf8.count <= 255,
        !name.contains("/"), !name.contains("\0"),
        home.utf8.count <= 1_024,
        seenUIDs.insert(uid).inserted
      else { continue }

      let shell = first(record, suffix: ":UserShell") ?? ""
      let displayName = first(record, suffix: ":RealName") ?? name
      let hiddenRaw = first(record, suffix: ":IsHidden")?.lowercased()
      let hidden = hiddenRaw == "1" || hiddenRaw == "true" || name.hasPrefix("_")
      let falseShells: Set<String> = [
        "/bin/false", "/usr/bin/false", "/sbin/nologin", "/usr/sbin/nologin",
      ]

      var exclusion: String?
      if hidden {
        exclusion = "Hidden account"
      } else if falseShells.contains(shell) {
        exclusion = "Account has a non-login shell"
      } else if !home.hasPrefix("/") {
        exclusion = "Account has no absolute home directory"
      } else {
        do {
          _ = try SecureDirectory.openAbsolute(home, finalOwner: uid_t(uid))
        } catch {
          exclusion = "Home directory is missing or unsafe"
        }
      }

      let installed: Bool
      let inspectionFailed: Bool
      do {
        installed = try AgentPlistStore.inspect(
          homeDirectory: home,
          uid: uid_t(uid),
          gid: gid_t(gid),
          userName: name
        ).isManaged
        inspectionFailed = false
      } catch {
        installed = false
        inspectionFailed = true
      }

      if exclusion == nil || installed || inspectionFailed {
        resultAccounts.append(
          LocalAccount(
            uid: uid,
            gid: gid,
            name: name,
            displayName: String(displayName.prefix(256)),
            homeDirectory: home,
            shell: String(shell.prefix(1_024)),
            isEligible: exclusion == nil,
            exclusionReason: exclusion
          )
        )
      }
    }
    return resultAccounts.sorted { ($0.uid, $0.name) < ($1.uid, $1.name) }
  }

  private func first(_ record: [String: Any], suffix: String) -> String? {
    guard let value = record.first(where: { $0.key.hasSuffix(suffix) })?.value else {
      return nil
    }
    if let strings = value as? [String] { return strings.first }
    return value as? String
  }

  private func uint32(_ record: [String: Any], suffix: String) -> UInt32? {
    guard let raw = first(record, suffix: suffix) else { return nil }
    return UInt32(raw)
  }
}
