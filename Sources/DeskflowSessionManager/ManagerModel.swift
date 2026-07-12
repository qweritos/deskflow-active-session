import AppKit
import DeskflowManagerCore
import Foundation
import ServiceManagement

enum HelperSetupState: Equatable {
  case checking
  case working(String)
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
  @Published private(set) var helperState: HelperSetupState = .checking
  @Published private(set) var helperVersion: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var activeOperation: ManagerOperation?
  @Published private(set) var operationStatus = ""
  @Published private(set) var lastOperationResponse: OperationResponse?
  @Published private(set) var hasUnknownMutationOutcome = false {
    didSet {
      defaults.set(hasUnknownMutationOutcome, forKey: unknownOutcomeDefaultsKey)
    }
  }
  @Published var selectedUserIDs: Set<UInt32> = [] {
    didSet { persistSelection() }
  }
  @Published var presentedError: PresentedManagerError?

  private let client: HelperClient
  private let service: SMAppService
  private let defaults: UserDefaults
  private var refreshTask: Task<Void, Never>?
  private var operationTask: Task<Void, Never>?
  private var helperCheckTask: Task<Void, Never>?
  private var refreshGeneration = 0
  private var helperGeneration = 0
  private var hasStoredSelection = false

  init(
    client: HelperClient = HelperClient(),
    defaults: UserDefaults = .standard
  ) {
    self.client = client
    self.defaults = defaults
    service = SMAppService.daemon(plistName: ManagerConstants.helperPlistName)
    restoreSelection()
    hasUnknownMutationOutcome = defaults.bool(forKey: unknownOutcomeDefaultsKey)
  }

  deinit {
    refreshTask?.cancel()
    operationTask?.cancel()
    helperCheckTask?.cancel()
  }

  var localDeskflowCoreAvailable: Bool {
    FileManager.default.isExecutableFile(
      atPath: ManagerConstants.deskflowCorePath
    )
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
    updateHelperState(refreshWhenEnabled: true)
  }

  func applicationDidBecomeActive() {
    updateHelperState(refreshWhenEnabled: snapshot == nil)
  }

  func updateHelperState(refreshWhenEnabled: Bool = false) {
    helperGeneration += 1
    let generation = helperGeneration
    helperCheckTask?.cancel()
    switch service.status {
    case .enabled:
      helperState = .enabled
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
    guard activeOperation == nil else { return }
    cancelHelperCheck()
    cancelRefresh()
    helperState = .working("Registering manager helper…")
    Task {
      do {
        try service.register()
        updateHelperState(refreshWhenEnabled: true)
      } catch {
        updateHelperState()
        showError(title: "Helper setup failed", error: error)
      }
    }
  }

  func repairHelper() {
    guard activeOperation == nil, !hasUnknownMutationOutcome else { return }
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
        try service.register()
        updateHelperState(refreshWhenEnabled: true)
      } catch {
        updateHelperState()
        showError(title: "Helper repair failed", error: error)
      }
    }
  }

  func removeManagementHelper() {
    guard canRemoveManagementHelper else { return }
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
      } catch {
        updateHelperState()
        showError(title: "Could not remove management helper", error: error)
      }
    }
  }

  func openLoginItemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  func refresh() {
    guard helperState.allowsStatus else {
      updateHelperState()
      return
    }

    refreshGeneration += 1
    let generation = refreshGeneration
    refreshTask?.cancel()
    isRefreshing = true
    refreshTask = Task {
      do {
        let newSnapshot = try await client.snapshot()
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        apply(newSnapshot)
        hasUnknownMutationOutcome = false
      } catch is CancellationError {
        // A newer refresh owns the visible state.
      } catch {
        guard generation == refreshGeneration else { return }
        classifyConnectionFailure(error)
        showError(title: "Status refresh failed", error: error)
      }
      if generation == refreshGeneration {
        isRefreshing = false
      }
    }
  }

  func selectAll() {
    guard let snapshot else { return }
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
    lastOperationResponse = nil
  }

  func openAccessibilitySettings() {
    openPrivacyPane("Privacy_Accessibility")
  }

  func openInputMonitoringSettings() {
    openPrivacyPane("Privacy_ListenEvent")
  }

  private func verifyHelperAndRefresh(
    generation: Int,
    refreshWhenEnabled: Bool
  ) {
    helperCheckTask = Task {
      do {
        let version = try await client.version()
        guard !Task.isCancelled, generation == helperGeneration else { return }
        helperVersion = version
        guard version == ManagerConstants.managerVersion else {
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
        classifyConnectionFailure(error)
      }
    }
  }

  private func perform(_ operation: ManagerOperation, userIDs: Set<UInt32>) {
    guard canMutate else { return }
    guard !userIDs.isEmpty else {
      presentedError = PresentedManagerError(
        title: "No applicable users selected",
        message: operation == .install
          ? "Select at least one eligible local desktop user."
          : "Select at least one user with an installed agent."
      )
      return
    }
    guard userIDs.count <= ManagerConstants.maximumSelectedUsers else {
      presentedError = PresentedManagerError(
        title: "Too many users selected",
        message:
          "Select no more than \(ManagerConstants.maximumSelectedUsers) local users at once."
      )
      return
    }

    activeOperation = operation
    cancelRefresh()
    operationStatus = "Requesting administrator authorization…"
    lastOperationResponse = nil
    operationTask = Task {
      do {
        let authorization = try await Task.detached(priority: .userInitiated) {
          try AuthorizationProvider.externalForm()
        }.value
        operationStatus = operation.progressDescription
        // Persist a conservative marker before sending the request. A process
        // exit or XPC interruption must not allow a second overlapping mutation.
        hasUnknownMutationOutcome = true
        let response = try await client.perform(
          operation: operation,
          userIDs: userIDs,
          authorization: authorization
        )
        hasUnknownMutationOutcome = false
        lastOperationResponse = bounded(response)
        operationStatus = response.summary
        activeOperation = nil
        refresh()
      } catch is CancellationError {
        activeOperation = nil
        operationStatus = ""
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
        showError(
          title: title,
          error: error
        )
        refresh()
      }
    }
  }

  private func apply(_ newSnapshot: SystemSnapshot) {
    snapshot = newSnapshot
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
    helperGeneration += 1
    helperCheckTask?.cancel()
    helperCheckTask = nil
  }

  private func cancelRefresh() {
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
    else { return }
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
