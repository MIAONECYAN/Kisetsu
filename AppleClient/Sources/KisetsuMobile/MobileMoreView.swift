import SwiftUI

private enum MobileMoreDestination: String, CaseIterable, Identifiable {
  case mikan
  case brush
  case files
  case playlists
  case sites
  case settings
  case logs

  var id: String { rawValue }
  var title: String {
    switch self {
    case .mikan: "Mikan Project"
    case .brush: "站点刷流"
    case .files: "文件管理"
    case .playlists: "播放列表"
    case .sites: "站点管理"
    case .settings: "设置"
    case .logs: "日志"
    }
  }
  var subtitle: String {
    switch self {
    case .mikan: "按星期浏览当季番组与资源"
    case .brush: "查看刷流状态、流量与任务"
    case .files: "浏览和管理后端服务器文件"
    case .playlists: "查看 Plex 播放列表并生成季度清单"
    case .sites: "配置搜索、RSS 与刷流站点"
    case .settings: "后端连接和应用配置"
    case .logs: "查看本次 App 会话诊断"
    }
  }
  var systemImage: String {
    switch self {
    case .mikan: "calendar"
    case .brush: "arrow.up.arrow.down.circle"
    case .files: "folder"
    case .playlists: "rectangle.stack.badge.play"
    case .sites: "antenna.radiowaves.left.and.right"
    case .settings: "gearshape"
    case .logs: "doc.text"
    }
  }
}

struct MobileMoreView: View {
  var body: some View {
    List(MobileMoreDestination.allCases) { destination in
      NavigationLink(value: destination) {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text(destination.title)
            Text(destination.subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } icon: {
          Image(systemName: destination.systemImage)
            .foregroundStyle(.secondary)
        }
      }
    }
    .mobileNavigationTitle("更多")
    .navigationDestination(for: MobileMoreDestination.self) { destination in
      switch destination {
      case .mikan: MobileMikanProjectView()
      case .brush: MobileBrushView()
      case .files: MobileFileManagerView()
      case .playlists: MobilePlaylistView()
      case .sites: MobileSiteManagementView()
      case .settings: MobileSettingsView()
      case .logs: MobileLogsView()
      }
    }
  }
}

struct MobileBackendSetupView: View {
  @EnvironmentObject private var store: AppStore
  var isFirstRun: Bool
  var completion: () -> Void
  @State private var isChecking = false

  var body: some View {
    Form {
      Section {
        MobileFormTextField(
          label: "后端地址",
          prompt: "例如：http://192.168.1.10:8000",
          text: $store.backendURLDraft
        )
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
          .autocorrectionDisabled()
        MobileFormValidationMessage(message: backendURLValidationMessage)
      } header: {
        Text("后端地址")
      } footer: {
        Text("请输入 iPhone 可以访问的局域网或 HTTPS 地址。127.0.0.1 指向手机自身，不能连接电脑上的后端。")
      }

      Section("连接状态") {
        LabeledContent("状态", value: store.healthText)
        Text(store.backendConnectionDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .mobileStatusNavigationTitle(isFirstRun ? "连接 Kisetsu" : "后端连接")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !isFirstRun {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消", action: completion)
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("连接") {
          Task {
            isChecking = true
            await store.checkHealth()
            isChecking = false
            if store.healthText != "后端连接失败" && store.healthText != "后端地址无效" {
              completion()
            }
          }
        }
        .disabled(isChecking || backendURLValidationMessage != nil)
      }
    }
    .overlay {
      if isChecking {
        ProgressView("正在连接")
          .padding(18)
          .glassEffect(.regular, in: .rect(cornerRadius: 18))
      }
    }
  }

  private var backendURLValidationMessage: String? {
    do {
      _ = try BackendEndpoint.normalizedString(store.backendURLDraft)
      return nil
    } catch {
      return error.localizedDescription
    }
  }
}

struct MobileSettingsView: View {
  var body: some View {
    List(MobileSettingsDestination.allCases) { destination in
      NavigationLink(value: destination) {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text(destination.title)
            Text(destination.subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } icon: {
          Image(systemName: destination.systemImage)
            .foregroundStyle(.secondary)
        }
      }
    }
    .mobileStatusNavigationTitle("设置")
    .navigationDestination(for: MobileSettingsDestination.self) { destination in
      switch destination {
      case .backend: MobileBackendSettingsView()
      case .downloaders: MobileDownloaderSettingsView()
      case .organize: MobileOrganizeSettingsView()
      case .metadata: MobileMetadataSettingsView()
      case .notifications: MobileNotificationSettingsView()
      case .ai: MobileAISettingsView()
      case .episodeRules: MobileEpisodeRulesSettingsView()
      case .playlists: MobilePlaylistServerSettingsView()
      }
    }
  }
}

struct MobileLogsView: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    List {
      if store.logs.isEmpty {
        ContentUnavailableView("暂无会话日志", systemImage: "doc.text")
          .frame(maxWidth: .infinity, minHeight: 320)
          .listRowBackground(Color.clear)
      } else {
        ForEach(Array(store.logs.enumerated()), id: \.offset) { _, line in
          Text(line)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
      }
    }
    .mobileStatusNavigationTitle("日志")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("清空", systemImage: "trash", role: .destructive) { store.clearLogs() }
          .disabled(store.logs.isEmpty)
      }
    }
  }
}
