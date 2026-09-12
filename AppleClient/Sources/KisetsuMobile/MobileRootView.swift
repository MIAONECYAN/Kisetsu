import SwiftUI

enum MobileTab: String, CaseIterable, Identifiable {
  case overview
  case search
  case subscriptions
  case tasks
  case more

  var id: String { rawValue }

  var title: String {
    switch self {
    case .overview: "概览"
    case .search: "搜索"
    case .subscriptions: "订阅"
    case .tasks: "任务"
    case .more: "更多"
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "sparkles.tv"
    case .search: "magnifyingglass"
    case .subscriptions: "dot.radiowaves.left.and.right"
    case .tasks: "arrow.down.circle"
    case .more: "ellipsis"
    }
  }
}

struct MobileRootView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("mobileBackendConfigured") private var backendConfigured = false
  @State private var selection: MobileTab
  @State private var showingBackendSetup = false
  @StateObject private var notice = MobileNoticeState()

  init() {
    let environment = ProcessInfo.processInfo.environment
    let requestedTab = MobileDebugConfiguration.initialTab(environment: environment)
    _selection = State(initialValue: MobileTab(rawValue: requestedTab ?? "") ?? .overview)
  }

  var body: some View {
    TabView(selection: $selection) {
      Tab(MobileTab.overview.title, systemImage: MobileTab.overview.systemImage, value: MobileTab.overview) {
        NavigationStack {
          MobileOverviewView(isActive: isActive(.overview))
        }
      }
      Tab(MobileTab.search.title, systemImage: MobileTab.search.systemImage, value: MobileTab.search) {
        NavigationStack {
          MobileSearchView(isActive: isActive(.search))
        }
      }
      Tab(MobileTab.subscriptions.title, systemImage: MobileTab.subscriptions.systemImage, value: MobileTab.subscriptions) {
        NavigationStack {
          MobileSubscriptionsView(isActive: isActive(.subscriptions))
        }
      }
      Tab(MobileTab.tasks.title, systemImage: MobileTab.tasks.systemImage, value: MobileTab.tasks) {
        NavigationStack {
          MobileTasksView(isActive: isActive(.tasks))
        }
      }
      Tab(MobileTab.more.title, systemImage: MobileTab.more.systemImage, value: MobileTab.more) {
        NavigationStack {
          Group {
#if DEBUG
          if MobileDebugConfiguration.initialMoreDestination(environment: ProcessInfo.processInfo.environment) == "playlists" {
            MobilePlaylistView()
          } else {
            MobileMoreView()
          }
#else
          MobileMoreView()
#endif
          }
        }
      }
    }
    .tint(.primary)
    .onChange(of: store.operationStatus, initial: true) { _, status in
      notice.status = status.phase == .idle ? nil : status
    }
    .task(id: notice.status?.id) {
      guard let status = notice.status,
            let delay = MobileStatusPresentation.autoDismissDelay(for: status.phase) else { return }
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      dismissStatus(status)
    }
    .task {
      if MobileDebugConfiguration.usesFixturesAtRuntime {
        backendConfigured = true
        showingBackendSetup = false
        #if DEBUG
        if let status = MobileDebugConfiguration.fixtureStatus(
          environment: ProcessInfo.processInfo.environment
        ) {
          try? await Task.sleep(for: .milliseconds(500))
          guard !Task.isCancelled else { return }
          store.operationStatus = status
        }
        if ProcessInfo.processInfo.environment["KISETSU_MOBILE_FIXTURE_PROGRESS_UPDATES"] == "1",
           let initialSubscription = store.subscriptions.first {
          for snapshot in MobileSubscriptionProgressFixture.snapshots(for: initialSubscription) {
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard let index = store.subscriptions.firstIndex(where: { $0.id == snapshot.id }) else { return }
            store.subscriptions[index] = snapshot
          }
        }
        #endif
        return
      }
      showingBackendSetup = !backendConfigured || store.backendURL == AppStore.defaultBackendURL
      guard !showingBackendSetup else { return }
      await store.checkHealth()
    }
    .sheet(isPresented: $showingBackendSetup) {
      NavigationStack {
        MobileBackendSetupView(isFirstRun: !backendConfigured) {
          backendConfigured = true
          showingBackendSetup = false
        }
      }
      .interactiveDismissDisabled(!backendConfigured)
    }
    .environmentObject(notice)
  }

  private func isActive(_ tab: MobileTab) -> Bool {
    selection == tab
      && scenePhase == .active
      && (backendConfigured || MobileDebugConfiguration.usesFixturesAtRuntime)
  }

  private func dismissStatus(_ status: OperationStatus) {
    notice.dismiss(status)
  }
}

@MainActor
final class MobileNoticeState: ObservableObject {
  @Published var status: OperationStatus?

  func dismiss(_ status: OperationStatus) {
    guard self.status?.id == status.id else { return }
    self.status = nil
  }
}

struct MobileStatusToolbarModifier: ViewModifier {
  @EnvironmentObject private var notice: MobileNoticeState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showingStatusDetail = false

  func body(content: Content) -> some View {
    content.toolbar {
      if notice.status != nil {
        ToolbarItem(id: "mobile-operation-status", placement: .topBarLeading) {
          ZStack {
            if let status = notice.status {
              Button { showingStatusDetail = true } label: {
                HStack(spacing: 6) {
                  if status.phase == .loading {
                    ProgressView().controlSize(.mini)
                  } else {
                    Image(systemName: status.phase.iconName)
                  }
                  Text(status.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: 120)
                }
                .frame(minHeight: 44)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("\(status.title)，\(status.detail)")
              .accessibilityHint("查看完整状态消息")
              .accessibilityAction(named: "关闭通知") { dismissStatus(status) }
              .popover(isPresented: $showingStatusDetail) {
                VStack(alignment: .leading, spacing: 12) {
                  Text(status.title).font(.headline)
                  if !status.detail.isEmpty { Text(status.detail) }
                  Button("关闭通知", systemImage: "xmark") { dismissStatus(status) }
                    .buttonStyle(.glass)
                }
                .padding()
                .presentationCompactAdaptation(.popover)
              }
              .transition(statusTransition)
            }
          }
          .frame(height: 44)
          .animation(
            reduceMotion ? MobileMotion.reducedFade : MobileMotion.status,
            value: notice.status != nil
          )
        }
      }
    }
    .onChange(of: notice.status == nil) { _, isDismissed in
      if isDismissed { showingStatusDetail = false }
    }
  }

  private var statusTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    let hidden = AnyTransition.opacity.combined(with: .offset(y: -8))
    return .asymmetric(insertion: hidden, removal: hidden)
  }

  private func dismissStatus(_ status: OperationStatus) {
    showingStatusDetail = false
    notice.dismiss(status)
  }
}
