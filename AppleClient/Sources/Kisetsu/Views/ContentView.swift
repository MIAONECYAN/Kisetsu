import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
  case dashboard
  case settings
  case search
  case mikanProject
  case metadata
  case plex
  case subscriptions
  case tasks
  case brush
  case files
  case playlists
  case sites
  case logs

  static var allCases: [AppSection] {
    [.dashboard, .search, .mikanProject, .subscriptions, .tasks, .brush, .files, .playlists, .sites, .settings, .logs]
  }

  var id: String { rawValue }

  static func restored(from rawValue: String?) -> AppSection? {
    guard let rawValue else { return nil }
    if rawValue == "history" || rawValue == "organize" {
      return .tasks
    }
    return AppSection(rawValue: rawValue)
  }

  var title: String {
    switch self {
    case .dashboard: "概览"
    case .settings: "设置"
    case .search: "搜索"
    case .mikanProject: "Mikan Project"
    case .metadata: "番剧信息"
    case .plex: "整理规则"
    case .subscriptions: "订阅"
    case .tasks: "任务"
    case .brush: "站点刷流"
    case .files: "文件管理"
    case .playlists: "播放列表"
    case .sites: "站点管理"
    case .logs: "日志"
    }
  }

  var symbol: String {
    switch self {
    case .dashboard: "speedometer"
    case .settings: "gearshape"
    case .search: "magnifyingglass"
    case .mikanProject: "calendar"
    case .metadata: "film.stack"
    case .plex: "rectangle.stack"
    case .subscriptions: "dot.radiowaves.left.and.right"
    case .tasks: "arrow.down.circle"
    case .brush: "arrow.up.arrow.down.circle"
    case .files: "folder.badge.gearshape"
    case .playlists: "rectangle.stack.badge.play"
    case .sites: "antenna.radiowaves.left.and.right"
    case .logs: "doc.text"
    }
  }
}

struct ContentView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection: AppSection?

  init() {
    _selection = State(
      initialValue: AppSection.restored(from: DesktopDebugConfiguration.initialSection) ?? .dashboard
    )
  }

  var body: some View {
    NavigationSplitView {
      SidebarView(selection: $selection)
    } detail: {
      DetailView(selection: selection ?? .dashboard) { section in
        selection = section
      }
      .overlay(alignment: .top) {
        if store.operationStatus.phase == .failed {
          StatusBannerView(status: store.operationStatus)
            .padding(.top, 8)
            .padding(.horizontal, KisetsuStyle.pagePadding)
        }
      }
      .navigationTitle((selection ?? .dashboard).title)
      .toolbar {
        ToolbarItem {
          Button {
            Task { await store.bootstrap() }
          } label: {
            GlobalRefreshButtonLabel(
              presentation: GlobalRefreshPresentation(
                isRefreshing: store.isBootstrapping,
                reduceMotion: reduceMotion
              )
            )
          }
          .disabled(store.isBootstrapping)
          .help(store.isBootstrapping ? "正在刷新全部状态" : "刷新全部状态")
          .accessibilityLabel(store.isBootstrapping ? "正在刷新全部状态" : "刷新全部状态")
        }
      }
    }
    .frame(minWidth: 1040, minHeight: 680)
    .textFieldStyle(AppTextFieldStyle())
    .sheet(isPresented: $store.showingMetadataReview) {
      MetadataReviewSheet {
        store.showingMetadataReview = false
      }
    }
    .sheet(isPresented: $store.showingManualHistoryOrganizeSheet) {
      ManualHistoryOrganizeSheet {
        store.cancelManualHistoryOrganize()
      }
    }
    .sheet(isPresented: $store.showingBatchOrganizeSheet) {
      BatchOrganizeSheet {
        store.showingBatchOrganizeSheet = false
      }
    }
  }
}

struct GlobalRefreshPresentation: Equatable {
  static let symbolSize: CGFloat = 18

  let isRefreshing: Bool
  let reduceMotion: Bool

  var symbolName: String {
    isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
  }

  var usesFlowEffect: Bool {
    isRefreshing && !reduceMotion
  }
}

struct GlobalRefreshButtonLabel: View {
  let presentation: GlobalRefreshPresentation

  var body: some View {
    Image(systemName: presentation.symbolName)
      .symbolRenderingMode(presentation.isRefreshing ? .hierarchical : .monochrome)
      .foregroundStyle(presentation.isRefreshing ? Color.accentColor : Color.primary)
      .symbolEffect(
        .variableColor.iterative.reversing,
        options: .repeating,
        isActive: presentation.usesFlowEffect
      )
      .contentTransition(
        presentation.reduceMotion ? .identity : .symbolEffect(.replace)
      )
      .animation(
        presentation.reduceMotion ? nil : .easeOut(duration: 0.18),
        value: presentation.isRefreshing
      )
      .frame(
        width: GlobalRefreshPresentation.symbolSize,
        height: GlobalRefreshPresentation.symbolSize
      )
  }
}

private struct DetailView: View {
  var selection: AppSection
  var navigate: (AppSection) -> Void

  var body: some View {
    switch selection {
    case .dashboard:
      DashboardView(navigate: navigate)
    case .settings:
      SettingsView()
    case .search:
      SearchView()
    case .mikanProject:
      MikanProjectView()
    case .metadata:
      MetadataMatchView()
    case .plex:
      PlexMappingView()
    case .subscriptions:
      SubscriptionsView()
    case .tasks:
      DesktopTasksView()
    case .brush:
      BrushView()
    case .files:
      FileManagerView()
    case .playlists:
      PlaylistView()
    case .sites:
      SiteManagementView()
    case .logs:
      LogsView()
    }
  }
}
