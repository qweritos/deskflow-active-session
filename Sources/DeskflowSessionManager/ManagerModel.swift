import AppKit
import DeskflowManagerCore
import Foundation
import OSLog
import ServiceManagement

enum HelperSetupState: Equatable {
  case checking
  case working(String)
  case installationRequired
  case enabled
  case notRegistered
  case requiresApproval
  case notFound
  case repairRequired(String)

  var allowsStatus: Bool {
    if case .enabled = self { return true }
    return false
  }
}

struct PresentedManagerError: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

@MainActor
final class ManagerModel: ObservableObject {
  @Published private(set) var snapshot: SystemSnapshot?
  @Published private(set) var helperState: HelperSetupState = .checking {
    didSet {
      guard helperState != oldValue else { return }
      recordEvent("Helper state: \(helperState.logDescription)")
    }
  }
  @Published private(set) var helperVersion: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var activeOperation: ManagerOperation?
  @Published private(set) var operationStatus = ""
  @Published private(set) var lastOperationResponse: OperationResponse?
  @Published private(set) var eventLog: [ManagerLogEntry] = []
  @Published private(set) var hasUnknownMutationOutcome = false {
    didSet {
      defaults.set(hasUnknownMutationOutcome, forKey: unknownOutcomeDefaultsKey)
      if hasUnknownMutationOutcome != oldValue {
        recordEvent(
          hasUnknownMutationOutcome
            ? "Operation outcome marked unknown"
            : "Unknown operation outcome cleared",
          level: hasUnknownMutationOutcome ? .warning : .info
        )
      }
    }
  }
  @Published var selectedUserIDs: Set<UInt32> = [] {
    didSet {
      persistSelection()
      if selectedUserIDs != oldValue {
        recordEvent(
          "Selection: \(selectedUserIDs.sorted().map(String.init).joined(separator: ", "))"
        )
      }
    }
  }
  @Published var presentedError: PresentedManagerError? {
    didSet {
      if oldValue != nil, presentedError == nil {
        recordEvent("Error dialog dismissed", level: .debug)
      }
    }
  }

  private let client: HelperClient
  private let service: SMAppService
  private let defaults: UserDefaults
  private var refreshTask: Task<Void, Never>?
  private var operationTask: Task<Void, Never>?
  private var helperCheckTask: Task<Void, Never>?
  private var refreshGeneration = 0
  private var helperGeneration = 0
  private var hasStoredSelection = false
  private var nextLogEntryID: UInt64 = 1
  private let systemLogger = Logger(
    subsystem: ManagerConstants.appBundleIdentifier,
    category: "manager-events"
  )

  private static let maximumLogEntries = 500
  private static let maximumLogMessageCharacters = 2_048

  init(
    client: HelperClient = HelperClient(),
    defaults: UserDefaults = .standard
  ) {
    self.client = client
    self.defaults = defaults
    service = SMAppService.daemon(plistName: ManagerConstants.helperPlistName)
    restoreSelection()
    hasUnknownMutationOutcome = defaults.bool(forKey: unknownOutcomeDefaultsKey)
    recordEvent(
      "Manager initialized (version \(ManagerConstants.managerVersion), bundle \(Bundle.main.bundleURL.standardizedFileURL.path))"
    )
  }

  deinit {
    refreshTask?.cancel()
    operationTask?.cancel()
    helperCheckTask?.cancel()
  }

  func recordInterfaceEvent(_ message: String) {
    recordEvent(message, level: .debug)
  }

  func copyEventLog() {
    let contents = eventLog.map(\.exportLine).joined(separator: "\n")
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(contents, forType: .string)
    recordEvent("Event log copied to clipboard")
  }

  func clearEventLog() {
    eventLog.removeAll(keepingCapacity: true)
    recordEvent("Event log cleared")
  }

  var localDeskflowCoreAvailable: Bool {
    FileManager.default.isExecutableFile(
      atPath: ManagerConstants.deskflowCorePath
    )
  }

  private func recordEvent(
    _ message: String,
    level: ManagerLogLevel = .info
  ) {
    let singleLine = message
      .split(whereSeparator: \Character.isNewline)
      .joined(separator: " ⏎ ")
    let boundedMessage = String(
      singleLine.prefix(Self.maximumLogMessageCharacters)
    )
    let entry = ManagerLogEntry(
      id: nextLogEntryID,
      timestamp: Date(),
      level: level,
      message: boundedMessage
    )
    nextLogEntryID &+= 1
    if eventLog.count >= Self.maximumLogEntries {
      eventLog.removeFirst(eventLog.count - Self.maximumLogEntries + 1)
    }
    eventLog.append(entry)

    switch level {
    case .debug:
      systemLogger.debug("\(boundedMessage, privacy: .public)")
    case .info:
      systemLogger.info("\(boundedMessage, privacy: .public)")
    case .warning:
      systemLogger.warning("\(boundedMessage, privacy: .public)")
    case .error:
      systemLogger.error("\(boundedMessage, privacy: .public)")
    }
  }

  var selectedUsers: [UserStatus] {
    guard let snapshot else { return [] }
    return snapshot.users.filter { selectedUserIDs.contains($0.account.uid) }
  }

  var selectedEligibleIDs: Set<UInt32> {
    Set(
      selectedUsers.lazy
        .filter { $0.account.isEligible }
        .map { $0.account.uid }
    )
  }

  var selectedInstalledIDs: Set<UInt32> {
    Set(
      selectedUsers.lazy
        .filter(\.isInstalled)
        .map { $0.account.uid }
    )
  }

  var canMutate: Bool {
    helperState.allowsStatus
      && activeOperation == nil
      && !isRefreshing
      && !hasUnknownMutationOutcome
  }

  var canRemoveManagementHelper: Bool {
    guard
      activeOperation == nil,
      !isRefreshing,
      !hasUnknownMutationOutcome
    else { return false }
    switch helperState {
    case .checking, .working, .notRegistered:
      return false
    default:
      return true
    }
  }

  func start() {
    recordEvent(
      "Application started; Deskflow core \(localDeskflowCoreAvailable ? "available" : "missing")"
    )
    updateHelperState(refreshWhenEnabled: true)
  }

  func applicationDidBecomeActive() {
    recordEvent("Application became active", level: .debug)
    updateHelperState(refreshWhenEnabled: snapshot == nil)
  }

  func updateHelperState(refreshWhenEnabled: Bool = false) {
    helperGeneration += 1
    let generation = helperGeneration
    helperCheckTask?.cancel()
    let serviceStatus = service.status
    recordEvent(
      "Checking helper registration: \(serviceStatus.logDescription); refresh when enabled: \(refreshWhenEnabled)"
    )
    guard isRunningFromInstalledApplication else {
      cancelRefresh()
      helperVersion = nil
      helperState = .installationRequired
      return
    }
    switch serviceStatus {
    case .enabled:
      // Do not allow a status request until the helper has proved that it can
      // launch and that its protocol version matches this manager.
      helperState = .checking
      verifyHelperAndRefresh(
        generation: generation,
        refreshWhenEnabled: refreshWhenEnabled
      )
    case .notRegistered:
      cancelRefresh()
      helperVersion = nil
      helperState = .notRegistered
    case .requiresApproval:
      cancelRefresh()
      helperVersion = nil
      helperState = .requiresApproval
    case .notFound:
      cancelRefresh()
      helperVersion = nil
      helperState = .notFound
    @unknown default:
      cancelRefresh()
      helperVersion = nil
      helperState = .repairRequired("macOS returned an unknown helper registration state.")
    }
  }

  func setUpHelper() {
    guard activeOperation == nil else {
      recordEvent("Helper setup ignored while an operation is active", level: .warning)
      return
    }
    guard isRunningFromInstalledApplication else {
      recordEvent("Helper setup blocked outside /Applications", level: .warning)
      helperState = .installationRequired
      return
    }
    recordEvent("Registering management helper")
    cancelHelperCheck()
    cancelRefresh()
    helperState = .working("Registering manager helper…")
    Task {
      do {
        try service.register()
        recordEvent("Management helper registration request succeeded")
        updateHelperState(refreshWhenEnabled: true)
      } catch {
        updateHelperState()
        showError(title: "Helper setup failed", error: error)
      }
    }
  }

  func repairHelper() {
    guard activeOperation == nil, !hasUnknownMutationOutcome else {
      recordEvent("Helper repair ignored while changes are unresolved", level: .warning)
      return
    }
    guard isRunningFromInstalledApplication else {
      recordEvent("Helper repair blocked outside /Applications", level: .warning)
      helperState = .installationRequired
      return
    }
    recordEvent("Repairing management helper")
    cancelHelperCheck()
    cancelRefresh()
    helperState = .working("Repairing manager helper…")
    Task {
      do {
        if service.status == .notFound {
          // A stale Service Management record can report notFound. Best-effort
          // removal lets registration proceed; a genuinely missing job has
          // nothing to remove.
          try? await unregisterService()
        } else if service.status != .notRegistered {
          try await unregisterService()
        }
        recordEvent("Previous management helper registration removed", level: .debug)
        try service.register()
        recordEvent("Management helper re-registered")
        updateHelperState(refreshWhenEnabled: true)
      } catch {
        updateHelperState()
        showError(title: "Helper repair failed", error: error)
      }
    }
  }

  func removeManagementHelper() {
    guard canRemoveManagementHelper else {
      recordEvent("Helper removal ignored because it is currently unavailable", level: .warning)
      return
    }
    recordEvent("Removing management helper")
    cancelHelperCheck()
    cancelRefresh()
    helperState = .working("Removing management helper…")
    Task {
      do {
        if service.status != .notRegistered {
          try await unregisterService()
        }
        helperVersion = nil
        helperState = .notRegistered
        recordEvent("Management helper removed")
      } catch {
        updateHelperState()
        showError(title: "Could not remove management helper", error: error)
      }
    }
  }

  func openLoginItemSettings() {
    recordEvent("Opening Login Items settings")
    SMAppService.openSystemSettingsLoginItems()
  }

  func openApplicationsFolder() {
    recordEvent("Opening Applications folder")
    NSWorkspace.shared.open(
      URL(fileURLWithPath: "/Applications", isDirectory: true)
    )
  }

  func refresh() {
    guard helperState.allowsStatus else {
      recordEvent("Refresh requested while helper is unavailable", level: .warning)
      updateHelperState()
      return
    }

    refreshGeneration += 1
    let generation = refreshGeneration
    refreshTask?.cancel()
    isRefreshing = true
    recordEvent("Status refresh started (request \(generation))")
    refreshTask = Task {
      defer {
        if generation == refreshGeneration {
          isRefreshing = false
          refreshTask = nil
        }
      }
      do {
        let newSnapshot = try await client.snapshot()
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        apply(newSnapshot)
        hasUnknownMutationOutcome = false
        recordEvent("Status refresh completed (request \(generation))")
      } catch is CancellationError {
        recordEvent("Status refresh cancelled (request \(generation))", level: .debug)
      } catch {
        guard generation == refreshGeneration else { return }
        recordEvent(
          "Status refresh failed (request \(generation)): \(error.localizedDescription)",
          level: .error
        )
        classifyConnectionFailure(error)
        showError(title: "Status refresh failed", error: error)
      }
    }
  }

  func selectAll() {
    guard let snapshot else {
      recordEvent("Select All ignored before status was loaded", level: .warning)
      return
    }
    selectedUserIDs = Set(
      snapshot.users.lazy
        .filter { $0.account.isEligible || $0.isInstalled }
        .map { $0.account.uid }
        .prefix(ManagerConstants.maximumSelectedUsers)
    )
  }

  func clearSelection() {
    selectedUserIDs = []
  }

  func toggleSelection(_ uid: UInt32) {
    if selectedUserIDs.contains(uid) {
      selectedUserIDs.remove(uid)
    } else {
      guard selectedUserIDs.count < ManagerConstants.maximumSelectedUsers else {
        recordEvent(
          "Selection limit reached while adding uid \(uid)",
          level: .warning
        )
        presentedError = PresentedManagerError(
          title: "Selection limit reached",
          message:
            "Select no more than \(ManagerConstants.maximumSelectedUsers) local users at once."
        )
        return
      }
      selectedUserIDs.insert(uid)
    }
  }

  func installOrUpgrade() {
    perform(.install, userIDs: selectedEligibleIDs)
  }

  func restart() {
    perform(.restart, userIDs: selectedInstalledIDs)
  }

  func uninstall() {
    perform(.uninstall, userIDs: selectedInstalledIDs)
  }

  func dismissResults() {
    recordEvent("Operation results dismissed", level: .debug)
    lastOperationResponse = nil
  }

  func openAccessibilitySettings() {
    recordEvent("Opening Accessibility settings")
    openPrivacyPane("Privacy_Accessibility")
  }

  func openInputMonitoringSettings() {
    recordEvent("Opening Input Monitoring settings")
    openPrivacyPane("Privacy_ListenEvent")
  }

  private func verifyHelperAndRefresh(
    generation: Int,
    refreshWhenEnabled: Bool
  ) {
    recordEvent("Verifying management helper version", level: .debug)
    helperCheckTask = Task {
      do {
        let version = try await client.version()
        guard !Task.isCancelled, generation == helperGeneration else { return }
        helperVersion = version
        recordEvent("Management helper replied with version \(version)")
        guard version == ManagerConstants.managerVersion else {
          recordEvent(
            "Management helper version mismatch: expected \(ManagerConstants.managerVersion), received \(version)",
            level: .warning
          )
          helperState = .repairRequired(
            "Installed helper version \(version) does not match manager version \(ManagerConstants.managerVersion)."
          )
          return
        }
        helperState = .enabled
        if refreshWhenEnabled || snapshot == nil {
          refresh()
        }
      } catch {
        guard !Task.isCancelled, generation == helperGeneration else { return }
        recordEvent(
          "Management helper verification failed: \(error.localizedDescription)",
          level: .error
        )
        classifyConnectionFailure(error)
      }
    }
  }

  private func perform(_ operation: ManagerOperation, userIDs: Set<UInt32>) {
    guard canMutate else {
      recordEvent(
        "\(operation.rawValue.capitalized) request ignored while changes are unavailable",
        level: .warning
      )
      return
    }
    guard !userIDs.isEmpty else {
      recordEvent(
        "\(operation.rawValue.capitalized) request has no applicable users",
        level: .warning
      )
      presentedError = PresentedManagerError(
        title: "No applicable users selected",
        message: operation == .install
          ? "Select at least one eligible local desktop user."
          : "Select at least one user with an installed agent."
      )
      return
    }
    guard userIDs.count <= ManagerConstants.maximumSelectedUsers else {
      recordEvent(
        "\(operation.rawValue.capitalized) request exceeds the user limit",
        level: .warning
      )
      presentedError = PresentedManagerError(
        title: "Too many users selected",
        message:
          "Select no more than \(ManagerConstants.maximumSelectedUsers) local users at once."
      )
      return
    }

    let targetDescription = userIDs.sorted().map(String.init).joined(separator: ", ")
    recordEvent(
      "\(operation.rawValue.capitalized) requested for uid(s): \(targetDescription)"
    )
    activeOperation = operation
    cancelRefresh()
    operationStatus = "Requesting administrator authorization…"
    recordEvent("Requesting administrator authorization for \(operation.rawValue)")
    lastOperationResponse = nil
    operationTask = Task {
      do {
        let authorization = try await Task.detached(priority: .userInitiated) {
          try AuthorizationProvider.externalForm()
        }.value
        recordEvent("Administrator authorization received for \(operation.rawValue)")
        operationStatus = operation.progressDescription
        // Persist a conservative marker before sending the request. A process
        // exit or XPC interruption must not allow a second overlapping mutation.
        hasUnknownMutationOutcome = true
        recordEvent("Dispatching \(operation.rawValue) request to management helper")
        let response = try await client.perform(
          operation: operation,
          userIDs: userIDs,
          authorization: authorization
        )
        hasUnknownMutationOutcome = false
        lastOperationResponse = bounded(response)
        operationStatus = response.summary
        activeOperation = nil
        recordEvent(
          "\(operation.rawValue.capitalized) completed: \(response.summary)"
        )
        for result in response.results.prefix(ManagerConstants.maximumSelectedUsers) {
          recordEvent(
            "\(operation.rawValue.capitalized) result for \(result.userName) (uid \(result.uid)): \(result.succeeded ? "success" : "failure") — \(result.message)",
            level: result.succeeded ? .info : .warning
          )
        }
        refresh()
      } catch is CancellationError {
        activeOperation = nil
        operationStatus = ""
        recordEvent("\(operation.rawValue.capitalized) cancelled", level: .warning)
      } catch {
        activeOperation = nil
        operationStatus = ""
        let outcomeIsUnknown: Bool
        if let clientError = error as? ManagerClientError,
          case .mutationOutcomeUnknown = clientError
        {
          outcomeIsUnknown = true
          hasUnknownMutationOutcome = true
        } else {
          outcomeIsUnknown = false
          hasUnknownMutationOutcome = false
        }
        let title =
          outcomeIsUnknown
          ? "Operation outcome is unknown"
          : "\(operation.displayName) failed"
        recordEvent(
          "\(operation.rawValue.capitalized) failed: \(error.localizedDescription)",
          level: .error
        )
        showError(
          title: title,
          error: error
        )
        refresh()
      }
    }
  }

  private func apply(_ newSnapshot: SystemSnapshot) {
    let previousSnapshot = snapshot
    snapshot = newSnapshot
    let activeUser = newSnapshot.activeUserName ?? "login window"
    recordEvent(
      "Snapshot: active desktop \(activeUser); users \(newSnapshot.users.count); TCP 24800 listeners \(newSnapshot.portListeners.count)"
    )
    if previousSnapshot?.activeUserName != newSnapshot.activeUserName {
      recordEvent(
        "Active desktop changed from \(previousSnapshot?.activeUserName ?? "login window") to \(activeUser)"
      )
    }
    for user in newSnapshot.users {
      let serverPIDs = user.serverPIDs.map(String.init).joined(separator: ",")
      recordEvent(
        "User \(user.account.name) (uid \(user.account.uid)): health=\(user.health.rawValue), supervisor=\(user.supervisorState.rawValue), supervisorPID=\(user.supervisorPID.map(String.init) ?? "none"), serverPIDs=\(serverPIDs.isEmpty ? "none" : serverPIDs)",
        level: .debug
      )
    }
    for listener in newSnapshot.portListeners {
      recordEvent(
        "TCP 24800 listener: uid \(listener.uid), pid \(listener.pid), command \(listener.command)",
        level: .debug
      )
    }
    let visibleIDs = Set(newSnapshot.users.map { $0.account.uid })
    if hasStoredSelection {
      selectedUserIDs.formIntersection(visibleIDs)
    } else {
      selectedUserIDs = Set(
        newSnapshot.users.lazy
          .filter(\.isInstalled)
          .map { $0.account.uid }
          .prefix(ManagerConstants.maximumSelectedUsers)
      )
      hasStoredSelection = true
    }
  }

  private func classifyConnectionFailure(_ error: Error) {
    guard let clientError = error as? ManagerClientError else { return }
    recordEvent(
      "Classifying helper connection failure: \(clientError.localizedDescription)",
      level: .warning
    )
    if hasUnknownMutationOutcome {
      switch clientError {
      case .connection, .timedOut, .invalidReply, .oversizedReply:
        return
      default:
        break
      }
    }
    switch clientError {
    case .bundledHelperMissing, .codeSigning:
      helperState = .notFound
    case .incompatibleSchema:
      helperState = .repairRequired(clientError.localizedDescription)
    case .connection, .timedOut, .invalidReply, .oversizedReply:
      if service.status == .enabled {
        helperState = .repairRequired(clientError.localizedDescription)
      } else {
        updateHelperState()
      }
    default:
      break
    }
  }

  private func cancelHelperCheck() {
    if helperCheckTask != nil {
      recordEvent("Cancelling helper verification", level: .debug)
    }
    helperGeneration += 1
    helperCheckTask?.cancel()
    helperCheckTask = nil
  }

  private var isRunningFromInstalledApplication: Bool {
    Bundle.main.bundleURL.standardizedFileURL.path
      == ManagerConstants.managerAppPath
  }

  private func cancelRefresh() {
    if isRefreshing {
      recordEvent("Cancelling active status refresh", level: .debug)
    }
    refreshGeneration += 1
    refreshTask?.cancel()
    refreshTask = nil
    isRefreshing = false
  }

  private func unregisterService() async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      service.unregister { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }

  private func bounded(_ response: OperationResponse) -> OperationResponse {
    let results = response.results.prefix(ManagerConstants.maximumSelectedUsers).map {
      UserOperationResult(
        uid: $0.uid,
        userName: String($0.userName.prefix(256)),
        succeeded: $0.succeeded,
        message: String($0.message.prefix(2_048))
      )
    }
    return OperationResponse(
      operation: response.operation,
      results: results,
      summary: String(response.summary.prefix(4_096))
    )
  }

  private func showError(title: String, error: Error) {
    recordEvent(
      "Displaying error “\(title)”: \(error.localizedDescription)",
      level: .error
    )
    presentedError = PresentedManagerError(
      title: title,
      message: String(error.localizedDescription.prefix(8_192))
    )
  }

  private func restoreSelection() {
    guard
      let data = defaults.data(forKey: selectionDefaultsKey),
      let ids = try? JSONDecoder().decode([UInt32].self, from: data)
    else {
      return
    }
    selectedUserIDs = Set(ids.sorted().prefix(ManagerConstants.maximumSelectedUsers))
    hasStoredSelection = true
    recordEvent("Restored saved user selection", level: .debug)
  }

  private func persistSelection() {
    guard hasStoredSelection || !selectedUserIDs.isEmpty else { return }
    if let data = try? JSONEncoder().encode(selectedUserIDs.sorted()) {
      defaults.set(data, forKey: selectionDefaultsKey)
    }
  }

  private func openPrivacyPane(_ pane: String) {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
      )
    else {
      recordEvent("Could not create System Settings URL for \(pane)", level: .error)
      return
    }
    NSWorkspace.shared.open(url)
  }

  private var selectionDefaultsKey: String {
    "\(ManagerConstants.appBundleIdentifier).selected-user-uids"
  }

  private var unknownOutcomeDefaultsKey: String {
    "\(ManagerConstants.appBundleIdentifier).unknown-mutation-outcome"
  }
}

extension ManagerOperation {
  fileprivate var displayName: String {
    switch self {
    case .install: return "Install / Upgrade"
    case .restart: return "Restart"
    case .uninstall: return "Uninstall"
    }
  }

  fileprivate var progressDescription: String {
    switch self {
    case .install: return "Installing or upgrading selected users…"
    case .restart: return "Restarting selected users…"
    case .uninstall: return "Uninstalling selected users…"
    }
  }
}

extension HelperSetupState {
  fileprivate var logDescription: String {
    switch self {
    case .checking: return "checking"
    case .working(let message): return "working — \(message)"
    case .installationRequired: return "installation required"
    case .enabled: return "enabled"
    case .notRegistered: return "not registered"
    case .requiresApproval: return "approval required"
    case .notFound: return "not found"
    case .repairRequired(let reason): return "repair required — \(reason)"
    }
  }
}

extension SMAppService.Status {
  fileprivate var logDescription: String {
    switch self {
    case .notRegistered: return "not registered"
    case .enabled: return "enabled"
    case .requiresApproval: return "approval required"
    case .notFound: return "not found"
    @unknown default: return "unknown"
    }
  }
}
