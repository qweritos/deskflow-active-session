import CoreFoundation
import Foundation

internal enum AgentPlistState {
  case absent
  case valid(Data)
  case invalid(Data?, managed: Bool, reason: String)

  var isValid: Bool {
    if case .valid = self { return true }
    return false
  }

  var isManaged: Bool {
    switch self {
    case .valid:
      return true
    case .invalid(_, let managed, _):
      return managed
    case .absent:
      return false
    }
  }

  var detail: String? {
    if case .invalid(_, _, let reason) = self { return reason }
    return nil
  }

  var data: Data? {
    switch self {
    case .valid(let data): return data
    case .invalid(let data, _, _): return data
    case .absent: return nil
    }
  }
}

internal enum AgentPlistStore {
  static let fileName = "\(ManagerConstants.supervisorLabel).plist"
  private static let maximumPlistBytes = 128 * 1_024

  static func plistPath(for account: LocalAccount) -> String {
    account.homeDirectory + "/Library/LaunchAgents/" + fileName
  }

  static func inspect(
    homeDirectory: String,
    uid: uid_t,
    gid: gid_t,
    userName: String
  ) throws -> AgentPlistState {
    let home = try SecureDirectory.openAbsolute(homeDirectory, finalOwner: uid)
    guard
      let library = try home.childDirectory(
        "Library", create: false, owner: uid, group: gid, mode: 0o700
      )
    else { return .absent }
    guard
      let agents = try library.childDirectory(
        "LaunchAgents", create: false, owner: uid, group: gid, mode: 0o755
      )
    else { return .absent }
    guard
      let data = try agents.readRegularFile(
        fileName,
        maximumBytes: maximumPlistBytes,
        expectedOwner: uid,
        requireOwnerOnlyWrite: true
      )
    else {
      return .absent
    }
    return validate(data, homeDirectory: homeDirectory, userName: userName)
  }

  static func inspect(_ account: LocalAccount) throws -> AgentPlistState {
    try inspect(
      homeDirectory: account.homeDirectory,
      uid: uid_t(account.uid),
      gid: gid_t(account.gid),
      userName: account.name
    )
  }

  static func install(_ account: LocalAccount, data: Data) throws {
    guard
      case .valid = validate(
        data,
        homeDirectory: account.homeDirectory,
        userName: account.name
      )
    else {
      throw ManagerBackendError.invalidLaunchAgent("Generated LaunchAgent failed validation.")
    }

    let uid = uid_t(account.uid)
    let gid = gid_t(account.gid)
    let home = try SecureDirectory.openAbsolute(account.homeDirectory, finalOwner: uid)
    guard
      let library = try home.childDirectory(
        "Library", create: true, owner: uid, group: gid, mode: 0o700
      ),
      let agents = try library.childDirectory(
        "LaunchAgents", create: true, owner: uid, group: gid, mode: 0o755
      ),
      let logs = try library.childDirectory(
        "Logs", create: true, owner: uid, group: gid, mode: 0o755
      )
    else {
      throw ManagerBackendError.unsafeFileSystem(
        "Could not prepare directories for \(account.name).")
    }
    _ = try logs.childDirectory(
      "Deskflow", create: true, owner: uid, group: gid, mode: 0o755
    )
    try agents.atomicWrite(data, named: fileName, owner: uid, group: gid, mode: 0o644)
  }

  static func remove(_ account: LocalAccount, expectedData: Data) throws -> Bool {
    let uid = uid_t(account.uid)
    let gid = gid_t(account.gid)
    let home = try SecureDirectory.openAbsolute(account.homeDirectory, finalOwner: uid)
    guard
      let library = try home.childDirectory(
        "Library", create: false, owner: uid, group: gid, mode: 0o700
      ),
      let agents = try library.childDirectory(
        "LaunchAgents", create: false, owner: uid, group: gid, mode: 0o755
      )
    else { return false }
    return try agents.removeRegularFile(
      fileName,
      expectedData: expectedData,
      expectedOwner: uid,
      requireOwnerOnlyWrite: true
    )
  }

  static func render(for account: LocalAccount) throws -> Data {
    let output = account.homeDirectory + "/Library/Logs/Deskflow/active-session.out.log"
    let error = account.homeDirectory + "/Library/Logs/Deskflow/active-session.err.log"
    let plist: [String: Any] = [
      "Label": ManagerConstants.supervisorLabel,
      "ProgramArguments": [
        ManagerConstants.supervisorPath,
        "--core",
        ManagerConstants.deskflowCorePath,
      ],
      "RunAtLoad": true,
      "KeepAlive": true,
      "LimitLoadToSessionType": "Aqua",
      "ThrottleInterval": 5,
      "ExitTimeOut": 6,
      "StandardOutPath": output,
      "StandardErrorPath": error,
    ]
    return try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
  }

  static func validate(
    _ data: Data,
    homeDirectory: String,
    userName: String
  ) -> AgentPlistState {
    let propertyList: Any
    do {
      propertyList = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      )
    } catch {
      return .invalid(data, managed: false, reason: "LaunchAgent plist is malformed.")
    }
    guard let dictionary = propertyList as? [String: Any] else {
      return .invalid(data, managed: false, reason: "LaunchAgent plist is not a dictionary.")
    }

    let labelMatches = dictionary["Label"] as? String == ManagerConstants.supervisorLabel
    let arguments = dictionary["ProgramArguments"] as? [String]
    let helperMatches = arguments?.first == ManagerConstants.supervisorPath
    let managed = labelMatches && helperMatches
    guard managed else {
      return .invalid(
        data,
        managed: false,
        reason: "Existing plist does not belong to this manager."
      )
    }

    let commonKeys: Set<String> = [
      "Label",
      "ProgramArguments",
      "RunAtLoad",
      "KeepAlive",
      "LimitLoadToSessionType",
      "ThrottleInterval",
      "StandardOutPath",
      "StandardErrorPath",
    ]
    let allowedKeys = commonKeys.union(["ExitTimeOut"])
    let keys = Set(dictionary.keys)
    guard keys.isSubset(of: allowedKeys) else {
      return .invalid(data, managed: true, reason: "LaunchAgent contains unexpected keys.")
    }

    let legacyArguments = [ManagerConstants.supervisorPath]
    let canonicalArguments = [
      ManagerConstants.supervisorPath,
      "--core",
      ManagerConstants.deskflowCorePath,
    ]
    let expectedKeys: Set<String>
    if arguments == legacyArguments {
      expectedKeys = commonKeys
    } else if arguments == canonicalArguments {
      expectedKeys = allowedKeys
    } else {
      return .invalid(data, managed: true, reason: "LaunchAgent arguments are unexpected.")
    }
    guard keys == expectedKeys else {
      return .invalid(data, managed: true, reason: "LaunchAgent keys are not canonical.")
    }

    guard isTrueBoolean(dictionary["RunAtLoad"]),
      isTrueBoolean(dictionary["KeepAlive"]),
      isInteger(dictionary["ThrottleInterval"], equalTo: 5),
      dictionary["LimitLoadToSessionType"] as? String == "Aqua"
    else {
      return .invalid(data, managed: true, reason: "LaunchAgent lifecycle settings are unexpected.")
    }
    if arguments == canonicalArguments,
      !isInteger(dictionary["ExitTimeOut"], equalTo: 6)
    {
      return .invalid(data, managed: true, reason: "LaunchAgent exit timeout is unexpected.")
    }

    let expectedOutput = homeDirectory + "/Library/Logs/Deskflow/active-session.out.log"
    let expectedError = homeDirectory + "/Library/Logs/Deskflow/active-session.err.log"
    guard dictionary["StandardOutPath"] as? String == expectedOutput else {
      return .invalid(data, managed: true, reason: "LaunchAgent output path is unexpected.")
    }
    guard dictionary["StandardErrorPath"] as? String == expectedError else {
      return .invalid(data, managed: true, reason: "LaunchAgent error path is unexpected.")
    }
    _ = userName
    return .valid(data)
  }

  private static func isTrueBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else { return false }
    return number.boolValue
  }

  private static func isInteger(_ value: Any?, equalTo expected: Int) -> Bool {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      !CFNumberIsFloatType(number)
    else { return false }
    return number.int64Value == Int64(expected)
  }
}
