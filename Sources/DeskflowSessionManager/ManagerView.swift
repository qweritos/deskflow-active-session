import AppKit
import DeskflowManagerCore
import SwiftUI

struct ManagerView: View {
  @EnvironmentObject private var model: ManagerModel
  @State private var confirmation: ManagerConfirmation?
  @State private var hasStarted = false
  @AppStorage("io.github.qweritos.deskflow-active-session.manager.log-expanded")
  private var isEventLogExpanded = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          helperBanner
          deskflowBanner
          portBanner
          permissionBanner
          operationBanner
          reconciliationBanner
          accountSection
          resultSection
        }
        .padding(16)
      }

      Divider()
      actionBar
      Divider()
      eventLogPanel
    }
    .frame(minWidth: 820, minHeight: 560)
    .onAppear {
      guard !hasStarted else { return }
      hasStarted = true
      model.start()
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: NSApplication.didBecomeActiveNotification
      )
    ) { _ in
      guard hasStarted else { return }
      model.applicationDidBecomeActive()
    }
    .alert(item: $model.presentedError) { error in
      Alert(
        title: Text(error.title),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
    .alert(item: $confirmation) { confirmation in
      switch confirmation {
      case .uninstall(let names):
        return Alert(
          title: Text("Uninstall selected user agents?"),
          message: Text(
            "This removes the supervisor agent for \(names.joined(separator: ", ")). Deskflow settings, certificates, logs, and privacy decisions are preserved."
          ),
          primaryButton: .destructive(Text("Uninstall")) {
            model.uninstall()
          },
          secondaryButton: .cancel()
        )
      case .removeHelper:
        return Alert(
          title: Text("Remove management helper?"),
          message: Text(
            "This unregisters only the privileged management helper. Existing per-user LaunchAgents continue to operate."
          ),
          primaryButton: .destructive(Text("Remove Helper")) {
            model.removeManagementHelper()
          },
          secondaryButton: .cancel()
        )
      }
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "keyboard.badge.ellipsis")
        .font(.system(size: 30))
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text("Deskflow Active Session")
          .font(.title2.weight(.semibold))
        Text(statusSummary)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if model.isRefreshing {
        ProgressView()
          .controlSize(.small)
      }
      Button {
        model.refresh()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(
        !model.helperState.allowsStatus
          || model.isRefreshing
          || model.activeOperation != nil
      )
      .keyboardShortcut("r", modifiers: .command)
    }
    .padding(16)
  }

  @ViewBuilder
  private var helperBanner: some View {
    switch model.helperState {
    case .checking:
      ManagerBanner(
        icon: "hourglass",
        color: .secondary,
        title: "Checking management helper",
        message: "Waiting for macOS service status."
      ) {
        EmptyView()
      }
    case .working(let message):
      ManagerBanner(
        icon: "gearshape.2",
        color: .accentColor,
        title: "Management helper",
        message: message
      ) {
        ProgressView().controlSize(.small)
      }
    case .installationRequired:
      ManagerBanner(
        icon: "shippingbox",
        color: .orange,
        title: "Install the manager application",
        message:
          "The management helper can run only from \(ManagerConstants.managerAppPath). Run the project installer, then open the installed application."
      ) {
        Button("Show Applications") { model.openApplicationsFolder() }
      }
    case .enabled:
      EmptyView()
    case .notRegistered:
      ManagerBanner(
        icon: "wrench.and.screwdriver",
        color: .orange,
        title: "Manager setup is required",
        message:
          "Register the signed, on-demand helper used for multi-user status and administration."
      ) {
        Button("Set Up Helper") { model.setUpHelper() }
      }
    case .requiresApproval:
      ManagerBanner(
        icon: "person.badge.key",
        color: .orange,
        title: "Approve the management helper",
        message:
          "macOS requires an administrator to allow the helper in Login Items before it can run."
      ) {
        HStack {
          Button("Open Login Item Settings") {
            model.openLoginItemSettings()
          }
          Button("Check Again") { model.updateHelperState(refreshWhenEnabled: true) }
        }
      }
    case .notFound:
      ManagerBanner(
        icon: "exclamationmark.triangle",
        color: .red,
        title: "Management helper is missing",
        message:
          "The application bundle is incomplete or its helper signature cannot be verified. Reinstall the signed application."
      ) {
        Button("Repair Registration") { model.repairHelper() }
          .disabled(model.hasUnknownMutationOutcome)
      }
    case .repairRequired(let reason):
      ManagerBanner(
        icon: "arrow.triangle.2.circlepath",
        color: .orange,
        title: "Management helper needs repair",
        message: reason
      ) {
        Button("Repair / Update Helper") { model.repairHelper() }
          .disabled(model.hasUnknownMutationOutcome)
      }
    }
  }

  @ViewBuilder
  private var deskflowBanner: some View {
    if !deskflowIsAvailable {
      ManagerBanner(
        icon: "keyboard.badge.exclamationmark",
        color: .red,
        title: "Deskflow CLI core is missing",
        message: ManagerConstants.deskflowCorePath
      ) {
        Button("Show Applications") { model.openApplicationsFolder() }
      }
    }
  }

  private var permissionBanner: some View {
    ManagerBanner(
      icon: "hand.raised",
      color: .blue,
      title: "Keyboard and mouse permissions",
      message:
        "If input sharing is denied, add this exact executable to Accessibility and Input Monitoring:\n\(ManagerConstants.supervisorPath)"
    ) {
      HStack {
        Button("Accessibility") { model.openAccessibilitySettings() }
        Button("Input Monitoring") { model.openInputMonitoringSettings() }
      }
    }
  }

  @ViewBuilder
  private var portBanner: some View {
    if let snapshot = model.snapshot, snapshot.portListeners.count > 1 {
      ManagerBanner(
        icon: "exclamationmark.triangle.fill",
        color: .red,
        title: "Multiple Deskflow listeners",
        message:
          "\(snapshot.portListeners.count) processes are listening on TCP port 24800. Only the active account should own this port."
      ) {
        EmptyView()
      }
    } else if let snapshot = model.snapshot,
      let listener = snapshot.portListeners.first,
      let activeName = snapshot.activeUserName,
      let activeUID = snapshot.users.first(where: { $0.account.name == activeName })?.account.uid,
      listener.uid != activeUID
    {
      ManagerBanner(
        icon: "exclamationmark.triangle.fill",
        color: .orange,
        title: "Unexpected Deskflow listener",
        message:
          "TCP port 24800 is owned by uid \(listener.uid), not the active account \(activeName)."
      ) {
        EmptyView()
      }
    }
  }

  @ViewBuilder
  private var operationBanner: some View {
    if let operation = model.activeOperation {
      ManagerBanner(
        icon: operation.symbolName,
        color: .accentColor,
        title: operation.displayName,
        message: model.operationStatus
      ) {
        ProgressView().controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private var reconciliationBanner: some View {
    if model.hasUnknownMutationOutcome, model.activeOperation == nil {
      ManagerBanner(
        icon: "questionmark.diamond.fill",
        color: .orange,
        title: "Operation outcome needs confirmation",
        message:
          "The app did not receive a definitive reply to the last operation. Changes may still be completing. Install, restart, uninstall, and helper removal remain disabled until a status refresh succeeds."
      ) {
        Button("Refresh Status") { model.refresh() }
          .disabled(model.isRefreshing || !model.helperState.allowsStatus)
      }
    }
  }

  private var accountSection: some View {
    GroupBox {
      VStack(spacing: 0) {
        HStack {
          Text("Local desktop users")
            .font(.headline)
          Text(
            "\(model.selectedUserIDs.count) of \(ManagerConstants.maximumSelectedUsers) selected"
          )
          .foregroundStyle(.secondary)
          Spacer()
          Button("Select All") { model.selectAll() }
            .buttonStyle(.link)
          Button("Clear") { model.clearSelection() }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

        Divider()

        if let snapshot = model.snapshot {
          if snapshot.users.isEmpty {
            placeholder("No eligible or installed local desktop users were found.")
          } else {
            LazyVStack(spacing: 0) {
              ForEach(snapshot.users) { user in
                UserStatusRow(
                  user: user,
                  activeUserName: snapshot.activeUserName,
                  selected: model.selectedUserIDs.contains(user.account.uid),
                  toggle: { model.toggleSelection(user.account.uid) }
                )
                if user.id != snapshot.users.last?.id {
                  Divider().padding(.leading, 44)
                }
              }
            }
          }
        } else {
          placeholder(
            model.helperState.allowsStatus
              ? "Status has not been loaded yet."
              : "Set up and approve the management helper to load user status."
          )
        }
      }
    }
  }

  @ViewBuilder
  private var resultSection: some View {
    if let response = model.lastOperationResponse {
      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Label(response.operation.displayName, systemImage: response.operation.symbolName)
              .font(.headline)
            Spacer()
            Button("Dismiss") { model.dismissResults() }
              .buttonStyle(.link)
          }
          Text(response.summary)
            .foregroundStyle(.secondary)
          ForEach(response.results) { result in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.succeeded ? .green : .red)
              Text(result.userName)
                .frame(width: 150, alignment: .leading)
              Text(result.message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
              Spacer()
            }
          }
        }
        .padding(8)
      }
    }
  }

  private var actionBar: some View {
    HStack(spacing: 10) {
      if let version = model.helperVersion {
        Text("Helper \(version)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Remove Management Helper") {
        confirmation = .removeHelper
      }
      .disabled(!model.canRemoveManagementHelper)

      Divider().frame(height: 20)

      Button("Restart") { model.restart() }
        .disabled(!model.canMutate || model.selectedInstalledIDs.isEmpty)
      Button("Uninstall") {
        confirmation = .uninstall(
          model.selectedUsers.filter(\.isInstalled).map { $0.account.name }
        )
      }
      .disabled(!model.canMutate || model.selectedInstalledIDs.isEmpty)
      Button("Install / Upgrade") { model.installOrUpgrade() }
        .buttonStyle(.borderedProminent)
        .disabled(
          !model.canMutate
            || model.selectedEligibleIDs.isEmpty
            || !deskflowIsAvailable
        )
    }
    .padding(12)
  }

  private var eventLogPanel: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button {
          isEventLogExpanded.toggle()
          model.recordInterfaceEvent(
            "Event log \(isEventLogExpanded ? "expanded" : "collapsed")"
          )
        } label: {
          HStack(spacing: 8) {
            Image(
              systemName: isEventLogExpanded
                ? "chevron.down"
                : "chevron.right"
            )
            .font(.caption.weight(.semibold))
            Text("Event Log")
              .font(.callout.weight(.semibold))
            Text("\(model.eventLog.count)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            if !isEventLogExpanded, let latest = model.eventLog.last {
              Text(latest.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isEventLogExpanded {
          Button("Copy") { model.copyEventLog() }
            .buttonStyle(.link)
          Button("Clear") { model.clearEventLog() }
            .buttonStyle(.link)
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 34)

      if isEventLogExpanded {
        Divider()
        eventLogContents
      }
    }
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var eventLogContents: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(model.eventLog) { entry in
            ManagerEventLogRow(entry: entry)
          }
          Color.clear
            .frame(height: 1)
            .id(eventLogBottomID)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .frame(minHeight: 120, idealHeight: 180, maxHeight: 220)
      .onAppear {
        proxy.scrollTo(eventLogBottomID, anchor: .bottom)
      }
      .onChange(of: model.eventLog.last?.id) { _ in
        proxy.scrollTo(eventLogBottomID, anchor: .bottom)
      }
    }
  }

  private var eventLogBottomID: String {
    "manager-event-log-bottom"
  }

  private var deskflowIsAvailable: Bool {
    model.snapshot?.deskflowCoreAvailable ?? model.localDeskflowCoreAvailable
  }

  private var statusSummary: String {
    guard let snapshot = model.snapshot else {
      return "Manager \(ManagerConstants.managerVersion)"
    }
    let active = snapshot.activeUserName ?? "login window"
    let port: String
    if snapshot.portListeners.isEmpty {
      port = "Port 24800: free"
    } else if snapshot.portListeners.count == 1, let listener = snapshot.portListeners.first {
      let owner =
        snapshot.users.first(where: { $0.account.uid == listener.uid })?.account.name
        ?? "uid \(listener.uid)"
      port = "Port 24800: \(owner) (pid \(listener.pid))"
    } else {
      port = "Port 24800: conflict"
    }
    return
      "Active desktop: \(active) · \(port) · Updated \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))"
  }

  private func placeholder(_ message: String) -> some View {
    Text(message)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: 100)
      .padding()
  }
}

private struct ManagerEventLogRow: View {
  let entry: ManagerLogEntry

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(entry.timestamp.formatted(date: .omitted, time: .standard))
        .foregroundStyle(.secondary)
        .frame(width: 84, alignment: .leading)
      Image(systemName: entry.level.symbolName)
        .foregroundStyle(entry.level.color)
        .frame(width: 12)
      Text(entry.level.rawValue.uppercased())
        .foregroundStyle(entry.level.color)
        .frame(width: 58, alignment: .leading)
      Text(entry.message)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(.caption, design: .monospaced))
  }
}

extension ManagerLogLevel {
  fileprivate var symbolName: String {
    switch self {
    case .debug: return "circle.fill"
    case .info: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .error: return "xmark.octagon.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .debug: return .secondary
    case .info: return .blue
    case .warning: return .orange
    case .error: return .red
    }
  }
}

private enum ManagerConfirmation: Identifiable {
  case uninstall([String])
  case removeHelper

  var id: String {
    switch self {
    case .uninstall: return "uninstall"
    case .removeHelper: return "remove-helper"
    }
  }
}

private struct ManagerBanner<Actions: View>: View {
  let icon: String
  let color: Color
  let title: String
  let message: String
  @ViewBuilder let actions: Actions

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(color)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(message)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer(minLength: 12)
      actions
    }
    .padding(12)
    .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    .overlay(
      RoundedRectangle(cornerRadius: 9)
        .stroke(color.opacity(0.25), lineWidth: 1)
    )
  }
}

private struct UserStatusRow: View {
  let user: UserStatus
  let activeUserName: String?
  let selected: Bool
  let toggle: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Toggle(
        "",
        isOn: Binding(
          get: { selected },
          set: { _ in toggle() }
        )
      )
      .labelsHidden()
      .disabled(!user.account.isEligible && !user.isInstalled)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(user.account.displayName.isEmpty ? user.account.name : user.account.displayName)
            .fontWeight(.medium)
          if activeUserName == user.account.name {
            Text("ACTIVE")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(Color.accentColor.opacity(0.14), in: Capsule())
          }
        }
        Text("\(user.account.name) · UID \(user.account.uid)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(minWidth: 210, alignment: .leading)

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        Label(user.health.title, systemImage: user.health.symbolName)
          .foregroundStyle(user.health.color)
        Text(user.account.exclusionReason ?? user.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.trailing)
      }
      .frame(maxWidth: 390, alignment: .trailing)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .contentShape(Rectangle())
  }
}

extension UserHealth {
  fileprivate var title: String {
    switch self {
    case .notInstalled: return "Not installed"
    case .loggedOut: return "Logged out"
    case .active: return "Active"
    case .standby: return "Standby"
    case .starting: return "Starting"
    case .stopping: return "Stopping"
    case .needsAttention: return "Needs attention"
    case .unknown: return "Unknown"
    }
  }

  fileprivate var symbolName: String {
    switch self {
    case .active: return "checkmark.circle.fill"
    case .standby: return "pause.circle.fill"
    case .starting, .stopping: return "clock.fill"
    case .notInstalled, .loggedOut: return "circle"
    case .needsAttention: return "exclamationmark.triangle.fill"
    case .unknown: return "questionmark.circle.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .active: return .green
    case .standby: return .blue
    case .starting, .stopping: return .orange
    case .needsAttention: return .red
    case .notInstalled, .loggedOut, .unknown: return .secondary
    }
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

  fileprivate var symbolName: String {
    switch self {
    case .install: return "square.and.arrow.down"
    case .restart: return "arrow.clockwise"
    case .uninstall: return "trash"
    }
  }
}
