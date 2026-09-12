import AppKit
import SwiftUI

private struct GlobalLimitRow: View {
  var title: String
  @Binding var enabled: Bool
  @Binding var value: Double
  @Binding var unit: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(title, isOn: $enabled)
      if enabled {
        HStack {
          TextField("速度", value: $value, format: .number.precision(.fractionLength(0...1)))
            .frame(width: 110)
          Picker("单位", selection: $unit) {
            Text("KB/s").tag("KB/s")
            Text("MB/s").tag("MB/s")
          }
          .labelsHidden()
          .frame(width: 90)
          Spacer()
        }
      }
    }
  }
}

private enum DownloaderSettingsTab: String, CaseIterable, Identifiable {
  case general
  case qbittorrent
  case transmission

  var id: String { rawValue }
  var title: String {
    switch self {
    case .general: "通用"
    case .qbittorrent: "qBittorrent"
    case .transmission: "Transmission"
    }
  }
}

enum SettingsPage: String, CaseIterable, Identifiable {
  case basic
  case downloader
  case playlists
  case organize
  case metadata
  case notifications
  case ai
  case episodeRules

  var id: String { rawValue }

  var title: String {
    switch self {
    case .basic: "基础"
    case .downloader: "下载器"
    case .playlists: "播放列表"
    case .organize: "整理"
    case .metadata: "元数据"
    case .notifications: "通知"
    case .ai: "AI"
    case .episodeRules: "集数识别"
    }
  }

  var symbol: String {
    switch self {
    case .basic: "gearshape"
    case .downloader: "arrow.down.circle"
    case .playlists: "rectangle.stack.badge.play"
    case .organize: "folder.badge.gearshape"
    case .metadata: "film.stack"
    case .notifications: "bell.badge"
    case .ai: "sparkles"
    case .episodeRules: "number.circle"
    }
  }
}

private struct SettingsPagePicker: View {
  @Binding var selection: SettingsPage

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(SettingsPage.allCases) { page in
        SettingsNavigationRow(
          title: page.title,
          symbol: page.symbol,
          isSelected: selection == page
        ) {
          selection = page
        }
      }
    }
    .padding(.vertical, 2)
  }
}

struct SettingsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var showingTMDBKey = false
  @State private var showingAIKey = false
  @State private var showingBarkKey = false
  @State private var editingTMDBKey = false
  @State private var editingAIKey = false
  @State private var editingBarkKey = false
  @State private var confirmingClearTMDBKey = false
  @State private var confirmingClearAIKey = false
  @State private var confirmingClearBarkKey = false
  @State private var showingOrganizeTargetSheet = false
  @State private var selectedPage: SettingsPage = .basic
  @State private var selectedDownloaderTab: DownloaderSettingsTab = .general
  @State private var globalDownloadLimitEnabled = false
  @State private var globalUploadLimitEnabled = false
  @State private var globalDownloadLimitValue = 10.0
  @State private var globalUploadLimitValue = 10.0
  @State private var globalDownloadLimitUnit = "MB/s"
  @State private var globalUploadLimitUnit = "MB/s"

  private var tagsBinding: Binding<String> {
    Binding {
      store.qbittorrent.defaultTags.joined(separator: ",")
    } set: { value in
      store.qbittorrent.defaultTags = value
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
  }

  private var transmissionLabelsBinding: Binding<String> {
    Binding {
      store.transmission.defaultLabels.joined(separator: ",")
    } set: { value in
      store.transmission.defaultLabels = value
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 20) {
      SettingsPagePicker(selection: $selectedPage)
        .frame(width: 190)

      Form {
      if selectedPage == .basic {
      Section("后端") {
        LabeledTextField(label: "后端 URL", placeholder: "例如：http://127.0.0.1:8000", text: $store.backendURLDraft)
        VStack(alignment: .leading, spacing: 8) {
          Label(store.healthText, systemImage: store.healthText.contains("正常") ? "checkmark.circle.fill" : "info.circle")
            .foregroundStyle(store.healthText.contains("正常") ? .green : .secondary)
          Text(store.backendConnectionDetail)
            .font(.caption)
            .foregroundStyle(.secondary)
          if let checkedAt = store.backendLastCheckedAt {
            Text("最近检测：\(DateFormatter.statusTime.string(from: checkedAt))")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          Text("启动后端：在项目目录运行 ./script/start_backend.sh。端口被旧后端占用时可运行 ./script/stop_backend.sh 后重启。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        HStack {
          Button {
            Task { await store.checkHealth() }
          } label: {
            Label(store.isLoading ? "检测中..." : "检测后端连接", systemImage: "heart")
          }
          .disabled(store.isLoading)
          Button {
            store.resetBackendURLToDefault()
          } label: {
            Label("使用默认地址", systemImage: "arrow.counterclockwise")
          }
        }
      }
      }

      if selectedPage == .playlists {
        PlaylistServerSettingsSections()
      }

      if selectedPage == .downloader {
        Section {
          Picker("下载器设置", selection: $selectedDownloaderTab) {
            ForEach(DownloaderSettingsTab.allCases) { tab in
              Text(tab.title).tag(tab)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 430)
          .frame(maxWidth: .infinity, alignment: .center)
        }

        if selectedDownloaderTab == .general {
          Section("下载器用途") {
            downloaderPicker("订阅下载器", selection: $store.downloaderRouting.subscriptionDownloader)
            downloaderPicker("站点刷流下载器", selection: $store.downloaderRouting.brushDownloader)
            downloaderPicker("手动下载器", selection: $store.downloaderRouting.manualDownloader)
            HStack {
              Button {
                Task { await store.saveDownloaderRouting() }
              } label: {
                Label("保存用途设置", systemImage: "square.and.arrow.down")
              }
              .disabled(store.isLoading)
            }
          }
          Section("连接状态") {
            downloaderStatusRow(
              "qBittorrent",
              configured: store.downloaderStatuses.first { $0.downloader == "qbittorrent" }?.configured == true,
              text: store.qbittorrentConnectionText,
              succeeded: store.qbittorrentConnectionSucceeded,
              version: store.qbittorrentVersionText
            )
            downloaderStatusRow(
              "Transmission",
              configured: store.downloaderStatuses.first { $0.downloader == "transmission" }?.configured == true,
              text: store.transmissionConnectionText,
              succeeded: store.transmissionConnectionSucceeded,
              version: store.transmissionVersionText
            )
            Button {
              Task { await store.testAllDownloaders() }
            } label: {
              if store.isTestingAllDownloaders {
                HStack(spacing: 6) {
                  ProgressView()
                    .controlSize(.small)
                  Text("正在测试")
                }
              } else {
                Label("测试全部", systemImage: "bolt.horizontal")
              }
            }
            .disabled(store.isLoading || store.isTestingAllDownloaders)
          }
        }

        if selectedDownloaderTab == .qbittorrent {
          Section("qBittorrent") {
            LabeledTextField(label: "Web UI 地址", placeholder: "例如：http://127.0.0.1:8080", text: $store.qbittorrent.baseUrl)
            downloaderAddressContext(store.qbittorrent.baseUrl)
            LabeledTextField(label: "用户名", placeholder: "例如：admin", text: $store.qbittorrent.username)
            LabeledSecureField(
              label: "密码",
              placeholder: store.qbittorrent.passwordConfigured ? "已保存，留空保持不变" : "输入 qBittorrent Web UI 密码",
              text: $store.qbittorrent.password,
              reference: CredentialReference(scope: "qbittorrent", field: "password")
            )
            LabeledDirectoryPathField(
              label: "默认保存路径",
              placeholder: "输入路径或选择文件夹",
              path: optionalText($store.qbittorrent.defaultSavePath)
            )
            LabeledTextField(label: "分类", placeholder: "例如：anime", text: optionalText($store.qbittorrent.defaultCategory, defaultValue: "anime"))
            LabeledTextField(label: "标签", placeholder: "例如：kisetsu, anime", text: tagsBinding, help: "多个标签用逗号分隔。")
            connectionStatusRow(
              text: store.qbittorrentConnectionText,
              succeeded: store.qbittorrentConnectionSucceeded,
              version: store.qbittorrentVersionText,
              checkedAt: store.qbittorrentLastTestedAt
            )
            HStack {
              Button {
                Task { await store.saveQbittorrentConfig() }
              } label: {
                Label(store.isLoading ? "保存中..." : "保存配置", systemImage: "square.and.arrow.down")
              }
              .disabled(store.isLoading)
              Button {
                Task { await store.testQbittorrent() }
              } label: {
                Label(store.isLoading ? "测试中..." : "测试连接", systemImage: "bolt.horizontal")
              }
              .disabled(store.isLoading)
            }
          }
          globalLimitSection(name: "qBittorrent")
        }

        if selectedDownloaderTab == .transmission {
          Section("Transmission") {
            LabeledTextField(label: "RPC 地址", placeholder: "例如：http://127.0.0.1:9091", text: $store.transmission.baseUrl)
            downloaderAddressContext(store.transmission.baseUrl)
            LabeledTextField(label: "用户名", placeholder: "可选", text: $store.transmission.username)
            LabeledSecureField(
              label: "密码",
              placeholder: store.transmission.passwordConfigured ? "已保存，留空保持不变" : "输入 Transmission RPC 密码",
              text: $store.transmission.password,
              reference: CredentialReference(scope: "transmission", field: "password")
            )
            LabeledDirectoryPathField(
              label: "默认保存路径",
              placeholder: "输入路径或选择文件夹",
              path: optionalText($store.transmission.defaultSavePath)
            )
            LabeledTextField(label: "标签", placeholder: "例如：kisetsu", text: transmissionLabelsBinding, help: "Transmission 不支持分类，使用标签识别 Kisetsu 任务。")
            connectionStatusRow(
              text: store.transmissionConnectionText,
              succeeded: store.transmissionConnectionSucceeded,
              version: store.transmissionVersionText,
              checkedAt: store.transmissionLastTestedAt
            )
            HStack {
              Button {
                Task { await store.saveTransmissionConfig() }
              } label: {
                Label(store.isLoading ? "保存中..." : "保存配置", systemImage: "square.and.arrow.down")
              }
              .disabled(store.isLoading)
              Button {
                Task { await store.testTransmission() }
              } label: {
                Label(store.isLoading ? "测试中..." : "测试连接", systemImage: "bolt.horizontal")
              }
              .disabled(store.isLoading)
            }
          }
          globalLimitSection(name: "Transmission")
        }
      }

      if selectedPage == .metadata {
      Section("元数据") {
        LabeledContent("TMDB", value: store.metadataSettings.message)
        SecretSettingControl(
          label: "TMDB API Key",
          placeholder: "粘贴新的 TMDB API Key",
          text: $store.tmdbAPIKeyInput,
          isRevealed: $showingTMDBKey,
          isEditing: $editingTMDBKey,
          isConfigured: store.metadataSettings.tmdbApiKeyConfigured,
          maskedValue: store.metadataSettings.tmdbApiKeyMasked,
          configuredTitle: "已配置 TMDB API Key",
          notConfiguredTitle: "尚未配置 TMDB API Key",
          help: "留空保存会保留已配置的 Key；只有点击清除才会删除。",
          disabled: store.isLoading,
          onSave: {
            await store.saveMetadataSettings()
          },
          onClear: {
            confirmingClearTMDBKey = true
          },
          reference: CredentialReference(scope: "metadata", field: "tmdb_api_key")
        )
        LabeledContent("最近测试", value: store.tmdbTestText)
        HStack {
          Button {
            Task { await store.testTMDBSettings() }
          } label: {
            Label("测试 TMDB", systemImage: "checkmark.seal")
          }
          .disabled(store.isLoading)

        }
        Text("用于补充 TMDB 候选和标准命名信息。Key 默认隐藏，可显示和复制完整内容。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      }

      if selectedPage == .ai {
      Section("AI 辅助分析") {
        Toggle("启用 AI 辅助分析", isOn: $store.aiEnabled)
        FormField(label: "Provider") {
          Picker("Provider", selection: $store.aiProvider) {
            ForEach(AIProviderCatalog.options) { option in
              Text(option.title).tag(option.id)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }
        .onChange(of: store.aiProvider) { previousProvider, provider in
          store.switchAIProvider(from: previousProvider, to: provider)
        }
        LabeledTextField(
          label: "Base URL",
          placeholder: AIProviderCatalog.baseURLPlaceholder(for: store.aiProvider),
          text: $store.aiBaseURL,
          help: "xAI 与 DeepSeek 使用各自官方默认地址；自定义兼容服务可填写自己的 API Base URL。",
          disabled: store.aiProvider == "none"
        )
        SecretSettingControl(
          label: "AI API Key",
          placeholder: "粘贴你的 AI API Key",
          text: $store.aiAPIKeyInput,
          isRevealed: $showingAIKey,
          isEditing: $editingAIKey,
          isConfigured: store.aiSettings.apiKeyConfigured,
          maskedValue: store.aiSettings.apiKeyMasked,
          configuredTitle: "已配置 AI API Key",
          notConfiguredTitle: "尚未配置 AI API Key",
          help: "留空保存会保留已配置的 Key；只有点击清除才会删除。",
          disabled: store.aiProvider == "none" || store.isLoading,
          onSave: {
            await store.saveAISettings()
          },
          onClear: {
            confirmingClearAIKey = true
          },
          reference: CredentialReference(scope: "ai_settings", field: "api_key", item: store.aiProvider)
        )
        FormField(label: "Model", help: "可以从模型列表选择，也可以在获取失败时手动填写模型名。") {
          VStack(alignment: .leading, spacing: 8) {
            if !store.aiModels.isEmpty {
              Picker("Model", selection: $store.aiModel) {
                ForEach(store.aiModels) { model in
                  Text(model.id).tag(model.id)
                }
                Text("手动填写模型名").tag("")
              }
              .labelsHidden()
            }
            TextField("", text: $store.aiModel, prompt: Text(AIProviderCatalog.modelPlaceholder(for: store.aiProvider)))
              .disabled(store.aiProvider == "none")
              .accessibilityLabel("Model")
          }
        }
        LabeledContent("状态", value: store.aiSettings.message)
        LabeledContent("最近测试", value: store.aiTestText)
        LabeledContent("模型列表", value: store.aiModelListText)
        FormField(
          label: "智能订阅时使用 AI",
          help: store.aiSettings.configured
            ? "从搜索结果创建订阅时，自动识别番名、字幕组、分辨率和字幕语言。你可以在保存前修改。"
            : "配置 AI 后可启用。"
        ) {
          Toggle("智能订阅时使用 AI", isOn: $store.useAIForSmartSubscription)
            .disabled(!store.aiSettings.configured || store.aiProvider == "none")
        }
        HStack {
          Button {
            Task { await store.loadAIModels() }
          } label: {
            Label("获取模型列表", systemImage: "list.bullet.rectangle")
          }
          .disabled(store.isLoading || store.aiProvider == "none")
          Button {
            Task { await store.saveAISettings() }
          } label: {
            Label("保存 AI 设置", systemImage: "square.and.arrow.down")
          }
          .disabled(store.isLoading)
          Button {
            Task { await store.testAISettings() }
          } label: {
            Label("测试连接", systemImage: "checkmark.seal")
          }
          .disabled(store.isLoading || store.aiProvider == "none")
        }
        Text("AI 只会接收资源标题、可选订阅名/别名/站点和本地解析摘要；不会发送密码、Cookie、qBittorrent 信息、下载路径或 API Key。AI 建议必须手动确认后才能保存。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      }

      if selectedPage == .notifications {
      Section("通知") {
        Toggle("启用通知", isOn: $store.notificationsEnabled)
        Text(store.notificationSettings.message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Bark") {
        Toggle("启用 Bark", isOn: $store.barkEnabled)
          .disabled(!store.notificationsEnabled)
        LabeledTextField(label: "Bark Server 地址", placeholder: "https://api.day.app", text: $store.barkServerURL, help: "支持官方 Bark 或自建 Bark Server。", disabled: !store.notificationsEnabled)
        SecretSettingControl(
          label: "Bark Device Key",
          placeholder: "粘贴 Bark Device Key",
          text: $store.barkDeviceKeyInput,
          isRevealed: $showingBarkKey,
          isEditing: $editingBarkKey,
          isConfigured: store.notificationSettings.bark.hasDeviceKey,
          maskedValue: store.notificationSettings.bark.maskedDeviceKey,
          configuredTitle: "已配置 Bark Device Key",
          notConfiguredTitle: "尚未配置 Bark Device Key",
          help: "留空保存会保留已配置的 Key；只有点击清除才会删除。",
          disabled: !store.notificationsEnabled || !store.barkEnabled || store.isLoading,
          onSave: {
            await store.saveNotificationSettings()
          },
          onClear: {
            confirmingClearBarkKey = true
          },
          reference: CredentialReference(scope: "notifications", field: "device_key")
        )
        LabeledTextField(label: "通知分组", placeholder: "Kisetsu", text: $store.barkGroup, disabled: !store.notificationsEnabled)
        LabeledTextField(label: "通知铃声", placeholder: "可选，例如：bell", text: $store.barkSound, disabled: !store.notificationsEnabled)
        LabeledTextField(label: "通知图标 URL", placeholder: "可选，默认优先使用海报", text: $store.barkIcon, disabled: !store.notificationsEnabled)
        LabeledTextField(label: "跳转 URL", placeholder: "可选，例如 Kisetsu 本地地址", text: $store.barkURL, disabled: !store.notificationsEnabled)
        FormField(label: "通知级别") {
          Picker("通知级别", selection: $store.barkLevel) {
            Text("主动提醒").tag("active")
            Text("时效通知").tag("timeSensitive")
            Text("静默").tag("passive")
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .disabled(!store.notificationsEnabled)
        }
        Toggle("自动复制通知正文", isOn: $store.barkAutoCopy)
          .disabled(!store.notificationsEnabled)
        LabeledContent("最近测试", value: store.notificationTestText)
        HStack {
          Button {
            Task { await store.saveNotificationSettings() }
          } label: {
            Label("保存通知设置", systemImage: "square.and.arrow.down")
          }
          .disabled(store.isLoading)
          Button {
            Task { await store.testNotificationSettings() }
          } label: {
            Label("测试通知", systemImage: "bell.badge")
          }
          .disabled(store.isLoading || !store.notificationsEnabled || !store.barkEnabled)
        }
      }

      Section("通知事件") {
        Toggle("订阅通知", isOn: $store.notifySubscription)
        Toggle("下载通知", isOn: $store.notifyDownload)
        Toggle("整理通知", isOn: $store.notifyOrganize)
        Text("通知失败不会中断订阅刷新、下载提交或整理流程。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      }

      if selectedPage == .episodeRules {
      Section("集数识别规则") {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Label("集数识别", systemImage: "number.circle")
              .font(.headline)
            Spacer()
            Button {
              Task { await store.loadEpisodeRuleSettings() }
            } label: {
              Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(store.isLoading)
            Button {
              Task { await store.saveGlobalEpisodeRules() }
            } label: {
              Label("保存", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isLoading)
          }

          Text("这里添加的规则会用于所有订阅。某个订阅自己设置了规则时，会先按订阅规则识别，再用全局规则兜底。")
            .font(.caption)
            .foregroundStyle(.secondary)

          EpisodeRuleManagerView(
            rules: $store.globalEpisodeParseRules,
            builtinRules: store.builtinEpisodeParseRules,
            scopeTitle: "全局规则",
            emptyTitle: "还没有自定义规则",
            emptyDescription: "大多数情况下内置规则已经够用；如果某个资源站标题识别失败，可以添加自己的规则。"
          )
        }
        .padding(.vertical, 4)
      }
      }

      if selectedPage == .organize {
      Section("整理策略") {
        Toggle("新订阅默认开启下载完成后自动整理", isOn: $store.organizePolicy.autoOrganizeByDefault)
        Toggle("整理后清理空下载目录", isOn: Binding {
          store.organizePolicy.cleanEmptyDownloadDirs ?? true
        } set: { value in
          store.organizePolicy.cleanEmptyDownloadDirs = value
        })
        organizePolicyPicker

        Button {
          Task { await store.saveOrganizePolicy() }
        } label: {
          Label("保存整理策略", systemImage: "square.and.arrow.down")
        }
        .disabled(store.isLoading)
      }
      }

      if selectedPage == .organize {
      Section("整理目标") {
        if store.organizeTargets.isEmpty {
          ContentUnavailableView("还没有整理目标", systemImage: "folder.badge.plus", description: Text("添加一个媒体库目录，用于整理下载完成的文件。"))
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
          ForEach(store.organizeTargets) { target in
            OrganizeTargetSettingsRow(target: target) {
              store.editOrganizeTarget(target)
              showingOrganizeTargetSheet = true
            }
          }
        }

        Button {
          store.cancelOrganizeTargetEditing()
          showingOrganizeTargetSheet = true
        } label: {
          Label("新增整理目标", systemImage: "plus")
        }
      }
      }

      }
      .formStyle(.grouped)
      .frame(minWidth: 560, maxWidth: 860, alignment: .topLeading)
    }
    .padding(KisetsuStyle.pagePadding)
    .frame(maxWidth: KisetsuStyle.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .confirmationDialog("清除 TMDB API Key？", isPresented: $confirmingClearTMDBKey, titleVisibility: .visible) {
      Button("清除 TMDB API Key", role: .destructive) {
        Task {
          if await store.clearTMDBSettings() {
            editingTMDBKey = false
            showingTMDBKey = false
          }
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("清除后 TMDB 搜索将不可用，直到重新保存新的 Key。")
    }
    .confirmationDialog("清除 AI API Key？", isPresented: $confirmingClearAIKey, titleVisibility: .visible) {
      Button("清除 AI API Key", role: .destructive) {
        Task {
          if await store.clearAIAPIKey() {
            editingAIKey = false
            showingAIKey = false
          }
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("清除后 AI 辅助分析将无法连接，除非重新保存新的 Key。")
    }
    .confirmationDialog("清除 Bark Device Key？", isPresented: $confirmingClearBarkKey, titleVisibility: .visible) {
      Button("清除 Bark Device Key", role: .destructive) {
        Task {
          if await store.clearBarkDeviceKey() {
            editingBarkKey = false
            showingBarkKey = false
          }
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("清除后 Bark 通知将不可用，除非重新保存新的 Device Key。")
    }
    .sheet(isPresented: $showingOrganizeTargetSheet, onDismiss: {
      store.cancelOrganizeTargetEditing()
    }) {
      OrganizeTargetFormSheet(
        chooseFolder: chooseOrganizeTargetFolder,
        close: {
          showingOrganizeTargetSheet = false
        }
      )
      .environmentObject(store)
    }
    .onChange(of: selectedPage) { _, page in
      guard page == .downloader else { return }
      Task {
        await store.loadDownloaderSettings()
        syncGlobalLimitDraft()
      }
    }
    .onChange(of: selectedDownloaderTab) { _, _ in
      syncGlobalLimitDraft()
    }
  }

  @ViewBuilder
  private func downloaderPicker(_ title: String, selection: Binding<String>) -> some View {
    LabeledContent(title) {
      Picker(title, selection: selection) {
        Text("qBittorrent").tag("qbittorrent")
        Text("Transmission").tag("transmission")
      }
      .labelsHidden()
      .frame(width: 180)
    }
  }

  @ViewBuilder
  private func downloaderStatusRow(
    _ name: String,
    configured: Bool,
    text: String,
    succeeded: Bool,
    version: String
  ) -> some View {
    LabeledContent(name) {
      let displayText = configured ? text : "未配置"
      let isTesting = configured && text == "正在测试"
      let showsSuccess = configured && succeeded
      HStack(spacing: 6) {
        if isTesting {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: showsSuccess ? "checkmark.circle.fill" : "circle")
        }
        Text(showsSuccess && version != "未检测" ? "\(displayText) · \(version)" : displayText)
      }
      .foregroundStyle(showsSuccess ? .green : .secondary)
    }
  }

  @ViewBuilder
  private func connectionStatusRow(text: String, succeeded: Bool, version: String, checkedAt: Date?) -> some View {
    LabeledContent("连接状态") {
      VStack(alignment: .trailing, spacing: 3) {
        Label(text, systemImage: succeeded ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(succeeded ? .green : .secondary)
        if succeeded {
          Text("版本 \(version)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let checkedAt {
          Text(DateFormatter.statusTime.string(from: checkedAt))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  @ViewBuilder
  private func downloaderAddressContext(_ address: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("连接由 Kisetsu 后端发起，请填写后端电脑能够访问的地址。")
      if backendIsRemote && isLoopbackAddress(address) {
        Text("此回环地址指向后端所在电脑，不是当前 Mac；下载器与后端同机时可以继续使用。")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var backendIsRemote: Bool {
    guard let host = URLComponents(string: store.backendURL)?.host?.lowercased() else { return false }
    return !["127.0.0.1", "localhost", "::1"].contains(host)
  }

  private func isLoopbackAddress(_ value: String) -> Bool {
    let normalized = value.contains("://") ? value : "http://\(value)"
    guard let host = URLComponents(string: normalized)?.host?.lowercased() else { return false }
    return ["127.0.0.1", "localhost", "::1"].contains(host)
  }

  @ViewBuilder
  private func globalLimitSection(name: String) -> some View {
    Section("\(name) 全局限速") {
      Text(globalLimitSummary)
        .font(.subheadline)
      Text("只修改 \(name) 的全局限速，作用于该下载器中的全部任务。")
        .font(.caption)
        .foregroundStyle(.secondary)
      GlobalLimitRow(
        title: "全局下载限速",
        enabled: $globalDownloadLimitEnabled,
        value: $globalDownloadLimitValue,
        unit: $globalDownloadLimitUnit
      )
      GlobalLimitRow(
        title: "全局上传限速",
        enabled: $globalUploadLimitEnabled,
        value: $globalUploadLimitValue,
        unit: $globalUploadLimitUnit
      )
      HStack {
        Button {
          Task { await saveGlobalLimits() }
        } label: {
          Label("应用全局限速", systemImage: "speedometer")
        }
        .disabled(store.isLoading || !globalLimitsAreValid)
        Button {
          Task {
            if selectedDownloaderTab == .transmission {
              await store.loadTransmissionGlobalLimits()
            } else {
              await store.loadQBittorrentGlobalLimits()
            }
            syncGlobalLimitDraft()
          }
        } label: {
          Label("重新读取", systemImage: "arrow.clockwise")
        }
        .disabled(store.isLoading)
      }
    }
  }

  private var globalLimitsAreValid: Bool {
    (!globalDownloadLimitEnabled || globalDownloadLimitValue > 0)
      && (!globalUploadLimitEnabled || globalUploadLimitValue > 0)
  }

  private var globalLimitSummary: String {
    let limits = selectedDownloaderTab == .transmission ? store.transmissionGlobalLimits : store.qBittorrentGlobalLimits
    return "上传 \(limitText(limits.uploadLimit)) · 下载 \(limitText(limits.downloadLimit))"
  }

  private func limitText(_ bytes: Int) -> String {
    guard bytes > 0 else { return "不限速" }
    if bytes >= 1_048_576 { return String(format: "%.1f MB/s", Double(bytes) / 1_048_576) }
    return String(format: "%.0f KB/s", Double(bytes) / 1024)
  }

  private func limitBytes(enabled: Bool, value: Double, unit: String) -> Int {
    guard enabled else { return 0 }
    return Int(value * (unit == "MB/s" ? 1_048_576 : 1024))
  }

  private func syncGlobalLimitDraft() {
    let limits = selectedDownloaderTab == .transmission ? store.transmissionGlobalLimits : store.qBittorrentGlobalLimits
    let download = limits.downloadLimit
    let upload = limits.uploadLimit
    globalDownloadLimitEnabled = download > 0
    globalUploadLimitEnabled = upload > 0
    (globalDownloadLimitValue, globalDownloadLimitUnit) = editableLimit(download)
    (globalUploadLimitValue, globalUploadLimitUnit) = editableLimit(upload)
  }

  private func editableLimit(_ bytes: Int) -> (Double, String) {
    guard bytes > 0 else { return (10, "MB/s") }
    if bytes >= 1_048_576 { return (Double(bytes) / 1_048_576, "MB/s") }
    return (Double(bytes) / 1024, "KB/s")
  }

  private func saveGlobalLimits() async {
    let limits = QbittorrentGlobalLimits(
      downloadLimit: limitBytes(enabled: globalDownloadLimitEnabled, value: globalDownloadLimitValue, unit: globalDownloadLimitUnit),
      uploadLimit: limitBytes(enabled: globalUploadLimitEnabled, value: globalUploadLimitValue, unit: globalUploadLimitUnit)
    )
    if selectedDownloaderTab == .transmission {
      await store.saveTransmissionGlobalLimits(limits)
    } else {
      await store.saveQBittorrentGlobalLimits(limits)
    }
    syncGlobalLimitDraft()
  }

  private var organizePolicyPicker: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("整理完成后如何处理下载任务？")
        .font(.headline)
      Picker("整理完成后如何处理下载任务？", selection: Binding {
        store.organizePolicy.postOrganizeAction ?? "remove_task_keep_files"
      } set: { action in
        store.setOrganizePolicyAction(action)
      }) {
        Text("继续做种").tag("keep_seeding")
        Text("移除任务，保留文件").tag("remove_task_keep_files")
        Text("移除任务并删除原下载文件").tag("remove_task_delete_files")
        Text("手动处理").tag("manual")
      }
      .labelsHidden()
      .pickerStyle(.radioGroup)

      if store.organizePolicy.postOrganizeAction == "keep_seeding" {
        VStack(alignment: .leading, spacing: 12) {
          Text("继续做种不是永远保留任务。达到停止条件后，会按下面动作处理。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("停止做种条件")
            .font(.subheadline.weight(.semibold))
          VStack(alignment: .leading, spacing: 4) {
            Text("达到分享率后停止")
            TextField("达到分享率后停止", text: optionalDoubleText($store.organizePolicy.seedingStopRatio), prompt: Text("例如 1.0"))
              .labelsHidden()
            Text("达到该分享率后自动处理任务。留空表示不按分享率停止。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("做种时长达到后停止")
            TextField("做种时长达到后停止", text: optionalIntText($store.organizePolicy.seedingStopMinutes), prompt: Text("例如 4320"))
              .labelsHidden()
            Text("单位：分钟。留空表示不按做种时长停止。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if store.organizePolicy.seedingStopRatio == nil && store.organizePolicy.seedingStopMinutes == nil {
            Label("未设置停止条件，将持续做种，直到你手动处理。", systemImage: "info.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Picker("满足方式", selection: Binding {
            store.organizePolicy.seedingStopMode ?? "any"
          } set: { value in
            store.organizePolicy.seedingStopMode = value
          }) {
            Text("任一条件满足").tag("any")
            Text("两个条件都满足").tag("all")
          }
          .pickerStyle(.segmented)
          Picker("停止后如何处理任务", selection: Binding {
            store.organizePolicy.postSeedingAction ?? "pause"
          } set: { value in
            store.organizePolicy.postSeedingAction = value
          }) {
            Text("仅暂停任务").tag("pause")
            Text("移除任务，保留文件").tag("remove_task_keep_files")
            Text("移除任务并删除原下载文件").tag("remove_task_delete_files")
            Text("手动处理").tag("manual")
          }
        }
        .padding(.leading, 22)
      }
    }
  }

  private func chooseOrganizeTargetFolder() {
    let panel = NSOpenPanel()
    panel.title = "选择整理目标文件夹"
    panel.prompt = "选择"
    panel.message = "请选择一个测试目录或媒体库目录。Kisetsu 只会保存路径，不会在这里移动文件。"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    let currentPath = store.organizeTargetPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !currentPath.isEmpty {
      panel.directoryURL = URL(fileURLWithPath: currentPath, isDirectory: true)
    }
    if panel.runModal() == .OK, let url = panel.url {
      store.organizeTargetPath = url.path
      store.lastOrganizeTargetValidation = nil
    }
  }

  private func optionalText(_ source: Binding<String?>, defaultValue: String = "") -> Binding<String> {
    Binding<String> {
      source.wrappedValue ?? defaultValue
    } set: { value in
      source.wrappedValue = value.isEmpty ? nil : value
    }
  }

  private func optionalDoubleText(_ source: Binding<Double?>) -> Binding<String> {
    Binding<String> {
      if let value = source.wrappedValue {
        return String(format: "%g", value)
      }
      return ""
    } set: { value in
      source.wrappedValue = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  private func optionalIntText(_ source: Binding<Int?>) -> Binding<String> {
    Binding<String> {
      source.wrappedValue.map(String.init) ?? ""
    } set: { value in
      source.wrappedValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}

private struct GlobalEpisodeRuleTestResult: View {
  var response: EpisodeRuleTestResponse

  var body: some View {
    let parsed = response.parsedTitle
    VStack(alignment: .leading, spacing: 4) {
      Label(response.message, systemImage: parsed.episode == nil ? "exclamationmark.triangle" : "checkmark.circle")
        .foregroundStyle(parsed.episode == nil ? .orange : .green)
      HStack(spacing: 10) {
        Text(parsed.isBatch == true ? "合集" : "单集")
        if let episode = parsed.episode {
          Text("集数 \(episode)")
        }
        if let start = parsed.episodeStart, let end = parsed.episodeEnd, parsed.isBatch == true {
          Text("范围 \(start)-\(end)")
        }
        if parsed.isFinal == true {
          Text("完结")
        }
        if let ruleName = parsed.parseRuleName {
          Text("规则 \(ruleName)")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if let reason = parsed.parseFailureReason {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }
}

private struct SecretSettingControl: View {
  var label: String
  var placeholder: String
  @Binding var text: String
  @Binding var isRevealed: Bool
  @Binding var isEditing: Bool
  var isConfigured: Bool
  var maskedValue: String?
  var configuredTitle: String
  var notConfiguredTitle: String
  var help: String
  var disabled: Bool
  var onSave: () async -> Bool
  var onClear: () -> Void
  var reference: CredentialReference

  var body: some View {
    FormField(label: label, help: help) {
      VStack(alignment: .leading, spacing: 8) {
        SecretValueField(label: label,
          prompt: isConfigured ? "已保存，留空保持不变" : placeholder,
          text: $text, reference: reference)
        HStack {
          Button("保存", systemImage: "checkmark") {
            Task { if await onSave() { text = ""; isEditing = false; isRevealed = false } }
          }
          .disabled(text.isEmpty)
          if isConfigured {
            Button("清除", systemImage: "trash", role: .destructive, action: onClear)
          }
        }
      }
      .disabled(disabled)
    }
  }
}

struct SiteManagementView: View {
  @EnvironmentObject private var store: AppStore
  @State private var selectedSiteID: String?
  @State private var selectedTemplateID = "dmhy"
  @State private var showingAddSiteSheet = false
  @State private var siteNavigationMessage: String?

  private let templates: [SiteTemplateOption] = [
    SiteTemplateOption(
      id: "dmhy",
      title: "动漫花园 / DMHY",
      subtitle: "中文动画资源聚合，适合日常搜索与订阅刷新。",
      primaryURL: "share.dmhy.org",
      symbol: "leaf",
      capabilities: ["搜索", "订阅刷新", "RSS"]
    ),
    SiteTemplateOption(
      id: "mikan",
      title: "蜜柑计划 / Mikan",
      subtitle: "番组页和 RSS 订阅友好，适合按动画追更。",
      primaryURL: "mikanani.me",
      symbol: "sparkle.magnifyingglass",
      capabilities: ["番组页", "RSS", "追番"]
    ),
    SiteTemplateOption(
      id: "nyaa",
      title: "Nyaa",
      subtitle: "英文资源站，补充更广的动画搜索来源。",
      primaryURL: "nyaa.si",
      symbol: "magnifyingglass.circle",
      capabilities: ["搜索", "补充源", "英文资源"]
    ),
    SiteTemplateOption(
      id: "mteam",
      title: "M-Team",
      subtitle: "私有 PT 站点，通过 API Key 搜索和获取种子。",
      primaryURL: "kp.m-team.cc",
      symbol: "key.horizontal",
      capabilities: ["PT", "API Key", "订阅刷新"]
    ),
    SiteTemplateOption(
      id: "soulvoice",
      title: "SoulVoice",
      subtitle: "NexusPHP 类 PT 站点，通过 Cookie 保持登录。",
      primaryURL: "pt.soulvoice.club",
      symbol: "person.crop.circle.badge.checkmark",
      capabilities: ["PT", "Cookie", "搜索"]
    ),
    SiteTemplateOption(
      id: "hddolby",
      title: "HD DOLBY",
      subtitle: "私有 PT 站点，通过 API Key 搜索和下载种子。",
      primaryURL: "www.hddolby.com",
      symbol: "waveform",
      capabilities: ["PT", "API Key", "订阅刷新"]
    ),
    SiteTemplateOption(
      id: "opencd",
      title: "OpenCD",
      subtitle: "NexusPHP 类音乐 PT 站点，通过 Cookie 搜索、订阅和刷流。",
      primaryURL: "open.cd",
      symbol: "opticaldisc",
      capabilities: ["PT", "Cookie", "站点刷流"]
    ),
  ]

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center) {
        Text("管理资源站点、镜像和 RSS 设置")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          showingAddSiteSheet = true
        } label: {
          Label(store.sitesLoaded ? "添加站点" : "查看站点库", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isLoading && store.sitesLoaded)
      }
      .appToolbarSurface()

      if store.sites.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: KisetsuStyle.sectionSpacing) {
            if !store.sitesLoaded {
              SiteBackendOfflineHint(
                backendURL: store.backendURL,
                detail: store.backendConnectionDetail
              ) {
                Task {
                  await store.checkHealth()
                  await store.loadSites()
                }
              }
            } else {
              EmptySiteManagementState(sitesLoaded: store.sitesLoaded) {
                showingAddSiteSheet = true
              }
            }

            if let siteNavigationMessage {
              Label(siteNavigationMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }
          .appPageContent()
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          SiteSettingsWorkspace(selectedSiteID: $selectedSiteID)

          if let siteNavigationMessage {
            Label(siteNavigationMessage, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        .appPageContent()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .sheet(isPresented: $showingAddSiteSheet) {
      AddSiteSheet(
        templates: templates,
        selectedTemplateID: $selectedTemplateID,
        isLoading: store.isLoading,
        sitesLoaded: store.sitesLoaded,
        existingSite: { template in
          store.sites.first { $0.id == template.id }
        },
        onAddTemplate: { template in
          activateTemplate(template)
          if store.sitesLoaded {
            showingAddSiteSheet = false
          }
        },
        onManageSite: { siteID in
          manageSite(siteID)
        }
      )
      .environmentObject(store)
    }
  }

  private func addTemplate(_ siteID: String) {
    if let existing = store.sites.first(where: { $0.id == siteID }) {
      selectedSiteID = existing.id
      return
    }
    Task {
      await store.addSiteTemplate(siteID)
      selectedSiteID = siteID
    }
  }

  private func activateTemplate(_ template: SiteTemplateOption) {
    selectedTemplateID = template.id
    addTemplate(template.id)
  }

  private func manageSite(_ siteID: String) {
    guard store.sites.contains(where: { $0.id == siteID }) else {
      siteNavigationMessage = "站点不存在或已被移除"
      return
    }
    selectedTemplateID = siteID
    selectedSiteID = siteID
    siteNavigationMessage = nil
    showingAddSiteSheet = false
  }
}

private struct SiteTemplateOption: Identifiable, Hashable {
  var id: String
  var title: String
  var subtitle: String
  var primaryURL: String
  var symbol: String
  var capabilities: [String]
}

private struct SiteBackendOfflineHint: View {
  var backendURL: String
  var detail: String
  var onRetry: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "bolt.horizontal.circle")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.orange)
        .frame(width: 34, height: 34)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      VStack(alignment: .leading, spacing: 3) {
        Text("后端未连接时仅显示模板预览")
          .font(.subheadline.weight(.semibold))
        Text("启动后端后可添加、保存和测试站点。当前地址：\(backendURL)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        if !detail.isEmpty {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer()
      Button(action: onRetry) {
        Label("重新连接", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(14)
    .animeCard(elevated: true)
    .frame(maxWidth: 960, alignment: .leading)
  }
}

private struct AddSiteSheet: View {
  var templates: [SiteTemplateOption]
  @Binding var selectedTemplateID: String
  var isLoading: Bool
  var sitesLoaded: Bool
  var existingSite: (SiteTemplateOption) -> SiteInfo?
  var onAddTemplate: (SiteTemplateOption) -> Void
  var onManageSite: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  private let columns = [
    GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 10, alignment: .top)
  ]

  private var filteredTemplates: [SiteTemplateOption] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return templates }
    return templates.filter { template in
      let haystack = ([template.title, template.primaryURL, template.subtitle] + template.capabilities).joined(separator: " ")
      return haystack.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("添加资源站点")
            .font(.title3.weight(.semibold))
          Text("选择要添加的资源站点。已添加的站点可直接跳到管理。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          dismiss()
        } label: {
          Label("关闭", systemImage: "xmark.circle")
        }
      }

      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("搜索站点、域名或能力", text: $searchText)
          .textFieldStyle(.plain)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(KisetsuStyle.subtleBorder)
      }

      if !sitesLoaded {
        Label("后端未连接时仅可预览站点库，启动后端后即可添加。", systemImage: "server.rack")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ScrollView {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
          ForEach(filteredTemplates) { template in
            let site = existingSite(template)
            SiteTemplateCard(
              template: template,
              isSelected: selectedTemplateID == template.id || site?.id == selectedTemplateID,
              state: templateState(site),
              isLoading: isLoading,
              onActivate: {
                selectedTemplateID = template.id
                if let site {
                  onManageSite(site.id)
                } else {
                  onAddTemplate(template)
                }
              }
            )
          }
        }
        .padding(.vertical, 2)

        if filteredTemplates.isEmpty {
          ContentUnavailableView("没有找到站点", systemImage: "magnifyingglass", description: Text("换个关键词再试试。"))
            .frame(maxWidth: .infinity, minHeight: 180)
        }
      }
      .frame(minHeight: 180, maxHeight: 360)
    }
    .padding(20)
    .frame(minWidth: 620, idealWidth: 720, minHeight: 360, idealHeight: 480)
  }

  private func templateState(_ site: SiteInfo?) -> SiteTemplateState {
    guard sitesLoaded else { return .waiting }
    guard let site else { return .available }
    return (site.enabled ?? true) ? .addedEnabled : .addedDisabled
  }
}

private struct EmptySiteManagementState: View {
  var sitesLoaded: Bool
  var onAddSite: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      ContentUnavailableView(
        sitesLoaded ? "还没有添加站点" : "等待后端连接",
        systemImage: sitesLoaded ? "antenna.radiowaves.left.and.right" : "server.rack",
        description: Text(sitesLoaded ? "打开站点库添加 DMHY、Mikan 或 Nyaa。" : "后端连接后即可保存站点设置。")
      )
      Button(action: onAddSite) {
        Label(sitesLoaded ? "添加站点" : "查看站点库", systemImage: "plus")
      }
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: 960, minHeight: 180)
    .animeCard(elevated: true)
  }
}

private enum SiteTemplateState: Equatable {
  case waiting
  case available
  case addedEnabled
  case addedDisabled

  var statusText: String {
    switch self {
    case .waiting:
      return "等待后端"
    case .available:
      return "可添加"
    case .addedEnabled:
      return "已添加"
    case .addedDisabled:
      return "已添加 · 已禁用"
    }
  }

  var actionText: String {
    switch self {
    case .waiting:
      return "等待"
    case .available:
      return "添加"
    case .addedEnabled, .addedDisabled:
      return ""
    }
  }

  var symbol: String {
    switch self {
    case .waiting:
      return "server.rack"
    case .available:
      return "plus.circle"
    case .addedEnabled:
      return "checkmark.circle.fill"
    case .addedDisabled:
      return "pause.circle"
    }
  }

  var color: Color {
    switch self {
    case .waiting:
      return .secondary
    case .available:
      return KisetsuStyle.animeTint
    case .addedEnabled:
      return .green
    case .addedDisabled:
      return .orange
    }
  }
}

private struct SiteTemplateCard: View {
  var template: SiteTemplateOption
  var isSelected: Bool
  var state: SiteTemplateState
  var isLoading: Bool
  var onActivate: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onActivate) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 9) {
          Image(systemName: template.symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(iconColor)
            .frame(width: 28, height: 28)
            .background(iconColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

          VStack(alignment: .leading, spacing: 3) {
            Text(template.title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)
            Text(template.primaryURL)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          Spacer(minLength: 8)

          SiteStatusPill(text: state.statusText, color: state.color, symbol: state.symbol)
        }

        HStack(spacing: 6) {
          ForEach(template.capabilities.prefix(2), id: \.self) { capability in
            Text(capability)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 7)
              .padding(.vertical, 4)
              .background(Color.secondary.opacity(0.09), in: Capsule())
          }
          Spacer(minLength: 8)
          if state.actionText.isEmpty {
            Image(systemName: "arrow.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(KisetsuStyle.animeTint)
          } else {
            Label(state.actionText, systemImage: state == .available ? "plus" : "arrow.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(state == .waiting ? .secondary : KisetsuStyle.animeTint)
          }
        }
      }
      .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isLoading || state == .waiting)
    .padding(12)
    .background(backgroundColor, in: RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous)
        .stroke(borderColor)
    }
    .onHover { hovering in
      isHovering = hovering
    }
  }

  private var iconColor: Color {
    isSelected ? KisetsuStyle.animeTint : state.color
  }

  private var backgroundColor: Color {
    if isSelected {
      return KisetsuStyle.animeTint.opacity(0.10)
    }
    if isHovering && state != .waiting {
      return Color.primary.opacity(0.045)
    }
    return Color.primary.opacity(0.025)
  }

  private var borderColor: Color {
    if isSelected {
      return KisetsuStyle.animeTint.opacity(0.45)
    }
    if isHovering && state != .waiting {
      return KisetsuStyle.animeTint.opacity(0.26)
    }
    return KisetsuStyle.subtleBorder
  }
}

private struct SiteStatusPill: View {
  var text: String
  var color: Color
  var symbol: String?

  var body: some View {
    HStack(spacing: 4) {
      if let symbol {
        Image(systemName: symbol)
          .font(.caption2.weight(.semibold))
      }
      Text(text)
    }
    .font(.caption2.weight(.semibold))
    .foregroundStyle(color)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(color.opacity(0.11), in: Capsule())
    .overlay {
      Capsule()
        .stroke(color.opacity(0.16))
    }
  }
}

private struct SiteSettingsWorkspace: View {
  @EnvironmentObject private var store: AppStore
  @Binding var selectedSiteID: String?
  @State private var draftSite: SiteInfo?
  @State private var savedSite: SiteInfo?
  @State private var pendingSelectionID: String?
  @State private var confirmingDiscard = false
  @State private var mirrorInput = ""
  @State private var mirrorError: String?
  @State private var mirrorMessage: String?
  @State private var domainTestMessage: String?
  @State private var domainTestOK: Bool?
  @State private var rssPreviewMessage: String?
  @State private var rssPreviewOK: Bool?
  @State private var rssPreviewResults: [SearchResult] = []
  @State private var rssPreviewCategories: [String] = []
  @State private var showingRSSPreviewSheet = false
  @State private var rssPreviewKeyword = ""
  @State private var rssPreviewCategory = ""
  @State private var rssPreviewLoading = false
  @State private var rssPreviewPage = 1
  @State private var rssPreviewPageSize = 25
  @State private var rssPreviewTotalPages = 0
  @State private var rssPreviewHasPrevious = false
  @State private var rssPreviewHasNext = false
  @State private var rssPreviewElapsedMs: Int?
  @State private var mirrorDeleteRequest: MirrorDeleteRequest?
  @State private var siteDeleteRequest: SiteInfo?

  private var hasUnsavedChanges: Bool {
    draftSite != savedSite
  }

  private var draftSiteBinding: Binding<SiteInfo> {
    Binding(
      get: { draftSite! },
      set: { draftSite = $0 }
    )
  }

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      SiteListPane(
        sites: store.sites,
        selectedSiteID: selectedSiteID,
        isLoading: store.isLoading,
        select: select,
        toggle: toggleSite
      )

      Group {
        if draftSite != nil {
          siteEditor
        } else {
          ContentUnavailableView("选择一个站点", systemImage: "slider.horizontal.3", description: Text("从左侧列表选择站点后编辑域名、镜像和启用状态。"))
            .frame(maxWidth: .infinity, minHeight: 280)
            .animeCard(elevated: true)
        }
      }
      .frame(maxWidth: 860, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: 1220, maxHeight: .infinity, alignment: .topLeading)
    .sheet(isPresented: $showingRSSPreviewSheet) {
      if let draftSite {
        RSSPreviewSheet(
          site: draftSite,
          message: rssPreviewMessage,
          ok: rssPreviewOK,
          results: rssPreviewResults,
          categories: rssPreviewCategories,
          page: rssPreviewPage,
          pageSize: rssPreviewPageSize,
          totalPages: rssPreviewTotalPages,
          hasPrevious: rssPreviewHasPrevious,
          hasNext: rssPreviewHasNext,
          elapsedMs: rssPreviewElapsedMs,
          keyword: $rssPreviewKeyword,
          category: $rssPreviewCategory,
          isLoading: rssPreviewLoading,
          refresh: {
            previewRSS(openSheet: false, resetPage: true)
          },
          previousPage: {
            previewRSS(openSheet: false, page: max(1, rssPreviewPage - 1))
          },
          nextPage: {
            previewRSS(openSheet: false, page: rssPreviewPage + 1)
          }
        )
        .environmentObject(store)
      }
    }
    .onAppear {
      if draftSite == nil {
        loadSite(selectedSiteID.flatMap(siteByID) ?? store.sites.first)
      }
    }
    .onChange(of: selectedSiteID) { _, siteID in
      guard let siteID, let site = siteByID(siteID), draftSite?.id != siteID else { return }
      if hasUnsavedChanges {
        pendingSelectionID = siteID
        confirmingDiscard = true
      } else {
        loadSite(site)
      }
    }
    .onChange(of: store.sites) { _, sites in
      guard !sites.isEmpty else {
        selectedSiteID = nil
        draftSite = nil
        savedSite = nil
        return
      }
      if selectedSiteID == nil {
        loadSite(sites.first)
      } else if !hasUnsavedChanges, let selectedSiteID, let site = sites.first(where: { $0.id == selectedSiteID }) {
        loadSite(site)
      }
    }
    .confirmationDialog("放弃未保存更改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
      Button("放弃更改", role: .destructive) {
        if let pendingSelectionID, let site = siteByID(pendingSelectionID) {
          loadSite(site)
        } else {
          draftSite = savedSite
        }
        pendingSelectionID = nil
      }
      Button("继续编辑", role: .cancel) {
        pendingSelectionID = nil
      }
    } message: {
      Text("当前站点有未保存更改，放弃后会恢复到上次保存的内容。")
    }
    .confirmationDialog("删除当前使用的镜像？", isPresented: Binding {
      mirrorDeleteRequest != nil
    } set: { visible in
      if !visible { mirrorDeleteRequest = nil }
    }, titleVisibility: .visible) {
      Button("删除并切回主域名", role: .destructive) {
        if let request = mirrorDeleteRequest {
          removeMirrorFromDraft(index: request.index, switchToPrimary: true)
        }
        mirrorDeleteRequest = nil
      }
      Button("取消", role: .cancel) {
        mirrorDeleteRequest = nil
      }
    } message: {
      Text("这个镜像正在作为当前使用的域名。删除后会自动切回主域名。")
    }
    .confirmationDialog("移除资源站点？", isPresented: Binding {
      siteDeleteRequest != nil
    } set: { visible in
      if !visible { siteDeleteRequest = nil }
    }, titleVisibility: .visible) {
      Button("移除站点", role: .destructive) {
        if let site = siteDeleteRequest {
          deleteSite(site)
        }
        siteDeleteRequest = nil
      }
      Button("取消", role: .cancel) {
        siteDeleteRequest = nil
      }
    } message: {
      Text("只会从站点管理中移除该站点，不会删除订阅、下载记录、qBittorrent 任务或任何文件。")
    }
  }

  private var siteEditor: some View {
    ScrollView {
      SiteDetailEditor(
        site: draftSiteBinding,
        isDirty: hasUnsavedChanges,
        isLoading: store.isLoading,
        mirrorInput: $mirrorInput,
        mirrorError: mirrorError,
        mirrorMessage: mirrorMessage,
        domainTestMessage: domainTestMessage,
        domainTestOK: domainTestOK,
        rssPreviewMessage: rssPreviewMessage,
        rssPreviewOK: rssPreviewOK,
        onAddMirror: addMirrorToDraft,
        onDeleteMirror: requestMirrorDeletion,
        onTestDomain: testCurrentDomain,
        onPreviewRSS: { previewRSS(resetPage: true) },
        onSave: saveDraft,
        onCancel: cancelEditing,
        onDeleteSite: requestSiteDeletion
      )
      .padding(.bottom, 2)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func siteByID(_ id: String) -> SiteInfo? {
    store.sites.first { $0.id == id }
  }

  private func select(_ site: SiteInfo) {
    guard selectedSiteID != site.id else { return }
    if hasUnsavedChanges {
      pendingSelectionID = site.id
      confirmingDiscard = true
    } else {
      loadSite(site)
    }
  }

  private func loadSite(_ site: SiteInfo?) {
    guard let site else { return }
    selectedSiteID = site.id
    draftSite = site
    savedSite = site
    mirrorInput = ""
    mirrorError = nil
    mirrorMessage = nil
    domainTestMessage = nil
    domainTestOK = nil
    resetRSSPreviewState()
  }

  private func toggleSite(_ site: SiteInfo, enabled: Bool) {
    if selectedSiteID == site.id, var draft = draftSite {
      draft.enabled = enabled
      draftSite = draft
      return
    }
    var updated = site
    updated.enabled = enabled
    Task {
      _ = await store.saveSite(updated)
    }
  }

  private func addMirrorToDraft() {
    let value = mirrorInput.trimmingCharacters(in: .whitespacesAndNewlines)
    mirrorError = nil
    mirrorMessage = nil
    guard !value.isEmpty else {
      mirrorError = "请先填写镜像地址。"
      return
    }
    guard isValidURL(value) else {
      mirrorError = "镜像地址格式不正确，请填写以 http:// 或 https:// 开头的完整地址。"
      return
    }
    guard var draft = draftSite else { return }
    let existing = Set(([draft.primaryUrl, draft.baseUrl].compactMap { $0 } + draft.mirrors).map { $0.lowercased() })
    guard !existing.contains(value.lowercased()) else {
      mirrorError = "这个域名已经在列表中。"
      return
    }
    draft.mirrors.append(value)
    draftSite = draft
    mirrorInput = ""
    mirrorMessage = "镜像已加入，保存后生效。"
    domainTestMessage = nil
    domainTestOK = nil
    resetRSSPreviewState()
  }

  private func requestMirrorDeletion(index: Int) {
    guard let draftSite, draftSite.mirrors.indices.contains(index) else { return }
    let url = draftSite.mirrors[index]
    if url == draftSite.activeBaseUrl {
      mirrorDeleteRequest = MirrorDeleteRequest(index: index, url: url)
    } else {
      removeMirrorFromDraft(index: index, switchToPrimary: false)
    }
  }

  private func removeMirrorFromDraft(index: Int, switchToPrimary: Bool) {
    guard var draft = draftSite, draft.mirrors.indices.contains(index) else { return }
    draft.mirrors.remove(at: index)
    if switchToPrimary {
      draft.activeBaseUrl = draft.primaryUrl ?? draft.baseUrl
    }
    draftSite = draft
    mirrorMessage = switchToPrimary ? "已删除镜像，并切回主域名。保存后生效。" : "镜像已删除，保存后生效。"
    domainTestMessage = nil
    domainTestOK = nil
    resetRSSPreviewState()
  }

  private func testCurrentDomain() {
    guard let draftSite else { return }
    let value = draftSite.activeBaseUrl ?? draftSite.primaryUrl ?? draftSite.baseUrl ?? ""
    guard isValidURL(value) else {
      domainTestMessage = "当前使用的域名格式不正确。"
      domainTestOK = false
      return
    }
    domainTestMessage = "正在测试当前域名..."
    domainTestOK = nil
    Task {
      do {
        let response = try await store.testSiteDomain(siteID: draftSite.id, url: value)
        await MainActor.run {
          domainTestMessage = response.message
          domainTestOK = response.ok
        }
      } catch {
        await MainActor.run {
          domainTestMessage = "当前域名无法访问，请检查网络或切换镜像。"
          domainTestOK = false
        }
      }
    }
  }

  private func resetRSSPreviewState() {
    rssPreviewMessage = nil
    rssPreviewOK = nil
    rssPreviewResults = []
    rssPreviewCategories = []
    rssPreviewLoading = false
    rssPreviewPage = 1
    rssPreviewPageSize = 25
    rssPreviewTotalPages = 0
    rssPreviewHasPrevious = false
    rssPreviewHasNext = false
    rssPreviewElapsedMs = nil
  }

  private func previewRSS(openSheet: Bool = true, page: Int? = nil, resetPage: Bool = false) {
    guard let draftSite else { return }
    if openSheet {
      showingRSSPreviewSheet = true
    }
    let targetPage = resetPage ? 1 : max(1, page ?? rssPreviewPage)
    rssPreviewPage = targetPage
    rssPreviewMessage = "正在读取 RSS..."
    rssPreviewOK = nil
    rssPreviewLoading = true
    if resetPage {
      rssPreviewResults = []
    }
    Task {
      do {
        let response = try await store.previewSiteRSS(site: draftSite, keyword: rssPreviewKeyword, category: rssPreviewCategory, page: targetPage, pageSize: rssPreviewPageSize)
        await MainActor.run {
          let elapsedText = response.elapsedMs.map { " · \($0)ms" } ?? ""
          rssPreviewMessage = "\(response.message)\(elapsedText)"
          rssPreviewOK = response.ok
          rssPreviewResults = response.results
          rssPreviewCategories = mergedRSSCategories(existing: response.categories, results: response.results)
          rssPreviewPage = response.page
          rssPreviewPageSize = response.pageSize
          rssPreviewTotalPages = response.totalPages
          rssPreviewHasPrevious = response.hasPrevious
          rssPreviewHasNext = response.hasNext
          rssPreviewElapsedMs = response.elapsedMs
          rssPreviewLoading = false
        }
      } catch {
        await MainActor.run {
          rssPreviewMessage = error.localizedDescription
          rssPreviewOK = false
          rssPreviewResults = []
          rssPreviewCategories = []
          rssPreviewHasPrevious = false
          rssPreviewHasNext = false
          rssPreviewLoading = false
        }
      }
    }
  }

  private func saveDraft() {
    guard let draftSite else { return }
    Task {
      if await store.saveSite(draftSite) {
        let refreshed = store.sites.first { $0.id == draftSite.id } ?? draftSite
        self.draftSite = refreshed
        savedSite = refreshed
        mirrorError = nil
        mirrorMessage = "站点设置已保存。"
        domainTestMessage = nil
        domainTestOK = nil
        resetRSSPreviewState()
      }
    }
  }

  private func cancelEditing() {
    if hasUnsavedChanges {
      pendingSelectionID = nil
      confirmingDiscard = true
    } else {
      draftSite = savedSite
      mirrorError = nil
      mirrorMessage = nil
      domainTestMessage = nil
      domainTestOK = nil
    }
  }

  private func requestSiteDeletion() {
    guard let draftSite else { return }
    siteDeleteRequest = draftSite
  }

  private func deleteSite(_ site: SiteInfo) {
    Task {
      if await store.deleteSite(site) {
        let next = store.sites.first
        selectedSiteID = next?.id
        draftSite = next
        savedSite = next
        mirrorInput = ""
        mirrorError = nil
        mirrorMessage = nil
        domainTestMessage = nil
        domainTestOK = nil
        resetRSSPreviewState()
      }
    }
  }

  private func isValidURL(_ value: String) -> Bool {
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host?.isEmpty == false else {
      return false
    }
    return true
  }

  private func mergedRSSCategories(existing: [String], results: [SearchResult]) -> [String] {
    let next = results.compactMap { result -> String? in
      let value = result.category?.trimmingCharacters(in: .whitespacesAndNewlines)
      return value?.isEmpty == false ? value : nil
    }
    return Array(Set(existing + next)).sorted()
  }
}

private struct SiteListPane: View {
  var sites: [SiteInfo]
  var selectedSiteID: String?
  var isLoading: Bool
  var select: (SiteInfo) -> Void
  var toggle: (SiteInfo, Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text("已添加站点")
          .font(.headline)
        Text("管理已添加站点的域名、镜像和启用状态。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 8) {
            ForEach(sites) { site in
              SiteSummaryRow(
                site: site,
                isSelected: selectedSiteID == site.id,
                isLoading: isLoading,
                onSelect: { select(site) },
                onToggle: { enabled in toggle(site, enabled) }
              )
              .id(site.id)
            }
          }
        }
        .frame(maxHeight: .infinity)
        .onChange(of: selectedSiteID) { _, siteID in
          guard let siteID else { return }
          withAnimation(.snappy(duration: 0.22)) {
            proxy.scrollTo(siteID, anchor: .center)
          }
        }
      }
    }
    .frame(width: 310, alignment: .topLeading)
    .frame(maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct SiteSummaryRow: View {
  var site: SiteInfo
  var isSelected: Bool
  var isLoading: Bool
  var onSelect: () -> Void
  var onToggle: (Bool) -> Void

  @State private var isHovering = false

  private var enabled: Bool {
    site.enabled ?? true
  }

  private var currentURL: String {
    site.activeBaseUrl ?? site.primaryUrl ?? site.baseUrl ?? "未设置"
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: enabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(statusColor)
          .frame(width: 22, height: 22)
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .center, spacing: 6) {
            Text(site.label)
              .font(.subheadline.weight(.medium))
              .foregroundStyle(.primary)
              .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
              Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
              Text(enabled ? "启用" : "禁用")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
          }
          Text(currentURL)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
          HStack(spacing: 8) {
            Text(site.id.uppercased())
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
            Text("\(site.mirrors.count) 个镜像")
              .font(.caption2)
              .foregroundStyle(.secondary)
            if authConfigured {
              Text("认证已配置")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if site.brushOnly == true {
              Text("仅刷流")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Color.secondary.opacity(0.55))
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Toggle("启用此站点", isOn: Binding {
        enabled
      } set: { value in
        onToggle(value)
      })
      .labelsHidden()
      .controlSize(.mini)
      .disabled(isLoading)
      .help("启用此站点")
    }
    .padding(11)
    .background(rowBackground, in: RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous))
    .contentShape(Rectangle())
    .onTapGesture {
      if !isLoading {
        onSelect()
      }
    }
    .onHover { hovering in
      isHovering = hovering
    }
  }

  private var statusColor: Color {
    enabled ? .green : .secondary
  }

  private var authConfigured: Bool {
    (site.apiKeyConfigured ?? false) || (site.cookieConfigured ?? false) || (site.passkeyConfigured ?? false)
  }

  private var rowBackground: Color {
    if isSelected {
      return KisetsuStyle.selectionBackground
    }
    if isHovering {
      return KisetsuStyle.hoverBackground
    }
    return Color.primary.opacity(0.018)
  }

  private var rowBorder: Color {
    if isSelected {
      return KisetsuStyle.animeTint.opacity(0.45)
    }
    if isHovering {
      return KisetsuStyle.animeTint.opacity(0.26)
    }
    return KisetsuStyle.subtleBorder
  }
}

private struct SiteDetailEditor: View {
  @Binding var site: SiteInfo
  var isDirty: Bool
  var isLoading: Bool
  @Binding var mirrorInput: String
  var mirrorError: String?
  var mirrorMessage: String?
  var domainTestMessage: String?
  var domainTestOK: Bool?
  var rssPreviewMessage: String?
  var rssPreviewOK: Bool?
  var onAddMirror: () -> Void
  var onDeleteMirror: (Int) -> Void
  var onTestDomain: () -> Void
  var onPreviewRSS: () -> Void
  var onSave: () -> Void
  var onCancel: () -> Void
  var onDeleteSite: () -> Void

  private var primaryURL: String {
    site.primaryUrl ?? site.baseUrl ?? ""
  }

  private var currentURL: String {
    site.activeBaseUrl ?? primaryURL
  }

  private var allBaseURLs: [String] {
    var urls: [String] = []
    if !primaryURL.isEmpty {
      urls.append(primaryURL)
    }
    urls.append(contentsOf: site.mirrors)
    return Array(Set(urls)).sorted()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label(site.label, systemImage: "slider.horizontal.3")
          .font(.headline)
        Spacer()
        if isDirty {
          Label("有未保存更改", systemImage: "circle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }

      VStack(alignment: .leading, spacing: 12) {
        Text("基本信息")
          .font(.subheadline.weight(.semibold))
        FormField(label: "显示名称", help: "会显示在搜索、订阅和刷新结果中。") {
          TextField("", text: Binding {
            site.displayName ?? site.name
          } set: { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            site.displayName = trimmed.isEmpty ? nil : value
          }, prompt: Text("例如：动漫花园 / DMHY"))
          .accessibilityLabel("显示名称")
        }
        Toggle("启用此站点", isOn: Binding {
          site.enabled ?? true
        } set: { value in
          site.enabled = value
        })
        if site.supportsBrush == true {
          Toggle("仅站点刷流", isOn: Binding {
            site.brushOnly ?? false
          } set: { value in
            site.brushOnly = value
          })
          .help("开启后，站点只参与刷流，不会出现在搜索和新建订阅中。")
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        Text("域名设置")
          .font(.subheadline.weight(.semibold))
        FormField(label: "主域名", help: "站点的默认官方地址或内置地址。") {
          TextField("", text: Binding {
            primaryURL
          } set: { value in
            site.primaryUrl = value.trimmingCharacters(in: .whitespacesAndNewlines)
          }, prompt: Text("例如：https://share.dmhy.org"))
          .accessibilityLabel("主域名")
        }
        FormField(label: "当前使用的域名", help: "搜索和订阅刷新会优先使用这个域名。可以从主域名或镜像中选择。") {
          Picker("当前使用的域名", selection: Binding {
            currentURL
          } set: { value in
            site.activeBaseUrl = value
          }) {
            ForEach(allBaseURLs, id: \.self) { url in
              Text(url).tag(url)
            }
          }
          .labelsHidden()
        }
      }

      Divider()

      if hasAuthSettings {
        VStack(alignment: .leading, spacing: 12) {
          Text("认证设置")
            .font(.subheadline.weight(.semibold))
          if authFields.contains("api_key") {
            SiteSecretSettingControl(label: "API Key", placeholder: "粘贴站点 API Key", valueName: "API Key", configuredTitle: "已配置 API Key", notConfiguredTitle: "尚未配置 API Key", configured: site.apiKeyConfigured, maskedValue: site.apiKeyMasked, text: Binding {
              site.apiKey
            } set: { value in
              site.apiKey = value
            }, clear: Binding {
              site.clearApiKey
            } set: { value in
              site.clearApiKey = value
            }, disabled: isLoading, reference: CredentialReference(scope: "site_settings", field: "api_key", item: site.id))
          }
          if authFields.contains("cookie") {
            SiteSecretSettingControl(label: "Cookie", placeholder: "粘贴站点 Cookie", valueName: "Cookie", configuredTitle: "已配置 Cookie", notConfiguredTitle: "尚未配置 Cookie", configured: site.cookieConfigured, maskedValue: site.cookieMasked, text: Binding {
              site.cookie
            } set: { value in
              site.cookie = value
            }, clear: Binding {
              site.clearCookie
            } set: { value in
              site.clearCookie = value
            }, disabled: isLoading, multiline: true, reference: CredentialReference(scope: "site_settings", field: "cookie", item: site.id))
          }
          if authFields.contains("passkey") {
            SiteSecretSettingControl(label: "Passkey", placeholder: "粘贴站点 Passkey", valueName: "Passkey", configuredTitle: "已配置 Passkey", notConfiguredTitle: "尚未配置 Passkey", configured: site.passkeyConfigured, maskedValue: site.passkeyMasked, text: Binding {
              site.passkey
            } set: { value in
              site.passkey = value
            }, clear: Binding {
              site.clearPasskey
            } set: { value in
              site.clearPasskey = value
            }, disabled: isLoading, reference: CredentialReference(scope: "site_settings", field: "passkey", item: site.id))
          }
          if authFields.contains("authorization") {
            SiteSecretSettingControl(label: "请求头（Authorization）", placeholder: "粘贴 Authorization 值", valueName: "Authorization", configuredTitle: "已配置 Authorization", notConfiguredTitle: "尚未配置 Authorization", configured: site.authorizationConfigured, maskedValue: site.authorizationMasked, text: Binding {
              site.authorization
            } set: { value in
              site.authorization = value
            }, clear: Binding {
              site.clearAuthorization
            } set: { value in
              site.clearAuthorization = value
            }, disabled: isLoading, reference: CredentialReference(scope: "site_settings", field: "authorization", item: site.id))
          }
          if authFields.contains("user_agent") {
            FormField(label: "User-Agent", help: "默认使用 Kisetsu 客户端标识；站点要求固定 UA 时再填写。") {
              TextField("", text: Binding {
                site.userAgent ?? ""
              } set: { value in
                site.userAgent = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
              }, prompt: Text("例如：Mozilla/5.0 ..."))
              .accessibilityLabel("User-Agent")
            }
          }
          Stepper(value: Binding {
            site.timeoutSeconds ?? 15
          } set: { value in
            site.timeoutSeconds = min(60, max(3, value))
          }, in: 3...60) {
            Text("请求超时 \(site.timeoutSeconds ?? 15) 秒")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if site.requestHeadersConfigured == true {
            LabeledSecureField(label: "旧版请求头", placeholder: "已保存，留空保持不变",
              text: .constant(""), reference: CredentialReference(scope: "site_settings", field: "request_headers", item: site.id))
            Button {
              site.clearRequestHeaders = !(site.clearRequestHeaders ?? false)
              if site.clearRequestHeaders == true {
                site.requestHeadersText = nil
              }
            } label: {
              Label(site.clearRequestHeaders == true ? "取消清除旧版请求头" : "清除旧版请求头", systemImage: site.clearRequestHeaders == true ? "arrow.uturn.backward.circle" : "trash.circle")
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(site.clearRequestHeaders == true ? .orange : .secondary)
          }
        }

        Divider()
      }

      VStack(alignment: .leading, spacing: 10) {
        Text("RSS")
          .font(.subheadline.weight(.semibold))
        SiteSecretSettingControl(label: "RSS 地址", placeholder: site.defaultRssUrl ?? "粘贴站点生成的 RSS 地址", valueName: "RSS 地址", configuredTitle: "已保存 RSS 地址", notConfiguredTitle: "尚未配置 RSS 地址", configured: site.rssUrlConfigured, maskedValue: site.rssUrlMasked, text: Binding {
          site.rssUrl
        } set: { value in
          site.rssUrl = value
        }, clear: Binding {
          site.clearRssUrl
        } set: { value in
          site.clearRssUrl = value
        }, disabled: isLoading, help: rssHelpText, reference: CredentialReference(scope: "site_settings", field: "rss_url", item: site.id))
        HStack(spacing: 8) {
          Button {
            onPreviewRSS()
          } label: {
            Label("预览 RSS", systemImage: "eye")
          }
          .disabled(isLoading)
          if let rssPreviewMessage {
            Label(rssPreviewMessage, systemImage: rssPreviewOK == false ? "exclamationmark.triangle" : "checkmark.circle")
              .font(.caption)
              .foregroundStyle(rssPreviewOK == false ? .orange : .green)
              .lineLimit(2)
          }
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        Text("镜像域名")
          .font(.subheadline.weight(.semibold))
        Text("当主域名不可用时，可以添加备用地址。")
          .font(.caption)
          .foregroundStyle(.secondary)
        if site.mirrors.isEmpty {
          Text("暂无镜像域名")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          VStack(spacing: 0) {
            ForEach(Array(site.mirrors.enumerated()), id: \.offset) { index, mirror in
              HStack(spacing: 8) {
                Text(mirror)
                  .font(.caption)
                  .lineLimit(1)
                Spacer()
                if mirror == currentURL {
                  Text("当前使用")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                }
                Button(role: .destructive) {
                  onDeleteMirror(index)
                } label: {
                  Label("删除", systemImage: "minus.circle")
                }
                .disabled(isLoading)
              }
              .padding(.vertical, 7)
              if index != site.mirrors.indices.last {
                Divider()
              }
            }
          }
          .padding(.horizontal, 10)
          .animeCard()
        }

        HStack(alignment: .top, spacing: 8) {
          FormField(label: "新增镜像域名", error: mirrorError) {
            TextField("", text: $mirrorInput, prompt: Text("例如：https://example.com"))
              .accessibilityLabel("新增镜像域名")
          }
          .frame(maxWidth: .infinity)
          Button {
            onAddMirror()
          } label: {
            Label("添加", systemImage: "plus.circle")
          }
          .disabled(isLoading)
          .padding(.top, 22)
        }
        if let mirrorMessage {
          Label(mirrorMessage, systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.green)
        }
      }

      Divider()

      HStack {
        Button(role: .destructive) {
          onDeleteSite()
        } label: {
          Label("移除站点", systemImage: "trash")
        }
        .disabled(isLoading)
        Spacer()
        Button {
          onTestDomain()
        } label: {
          Label("测试当前域名", systemImage: "network")
        }
        .disabled(isLoading)
        Button {
          onCancel()
        } label: {
          Label("取消", systemImage: "xmark.circle")
        }
        .disabled(isLoading)
        Button {
          onSave()
        } label: {
          Label("保存更改", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isLoading || !isDirty)
      }
      if let domainTestMessage {
        Label(domainTestMessage, systemImage: domainTestOK == false ? "exclamationmark.triangle" : "checkmark.circle")
          .font(.caption)
          .foregroundStyle(domainTestOK == false ? .orange : .green)
      }
    }
    .padding(14)
    .animeCard(elevated: true)
  }

  private var authFields: [String] {
    site.authFields ?? []
  }

  private var hasAuthSettings: Bool {
    !authFields.isEmpty
  }

  private var rssHelpText: String {
    if site.rssUrlConfigured == true {
      return "已保存 RSS 地址，留空保持不变。"
    }
    if let defaultRssUrl = site.defaultRssUrl, site.rssUrl?.isEmpty != false {
      return "留空会使用默认建议地址：\(defaultRssUrl)"
    }
    return "可粘贴站点生成的 RSS 地址；预览会使用当前认证和 Authorization。"
  }

  private func configuredText(configured: Bool?, masked: String?, name: String) -> String {
    if configured == true {
      if let masked, !masked.isEmpty {
        return "已保存：\(masked)。留空保存会保留旧值。"
      }
      return "已保存。留空保存会保留旧值。"
    }
    return "未配置 \(name)。"
  }

  @ViewBuilder
  private func secretClearButton(configured: Bool?, clear: Binding<Bool>, name: String = "凭证") -> some View {
    if configured == true {
      Button {
        clear.wrappedValue.toggle()
      } label: {
        Label(clear.wrappedValue ? "取消清除已保存\(name)" : "清除已保存\(name)", systemImage: clear.wrappedValue ? "arrow.uturn.backward.circle" : "trash.circle")
      }
      .font(.caption)
      .buttonStyle(.plain)
      .foregroundStyle(clear.wrappedValue ? .orange : .secondary)
    }
  }
}

private struct SiteSecretSettingControl: View {
  var label: String
  var placeholder: String
  var valueName: String
  var configuredTitle: String
  var notConfiguredTitle: String
  var configured: Bool?
  var maskedValue: String?
  @Binding var text: String?
  @Binding var clear: Bool?
  var disabled: Bool
  var multiline: Bool = false
  var help: String? = nil
  var reference: CredentialReference

  private var draftText: Binding<String> {
    Binding(get: { text ?? "" }, set: { value in
      text = value.isEmpty ? nil : value
      if !value.isEmpty { clear = false }
    })
  }

  var body: some View {
    FormField(label: label, help: help ?? "留空保存会保留已有值。") {
      VStack(alignment: .leading, spacing: 8) {
        SecretValueField(label: label,
          prompt: configured == true ? "已保存，留空保持不变" : placeholder,
          text: draftText, reference: reference)
        if configured == true {
          Toggle("保存后清除", isOn: Binding(
            get: { clear == true }, set: { clear = $0 }
          ))
        }
      }
      .disabled(disabled)
    }
  }
}

private struct MirrorDeleteRequest: Identifiable {
  var index: Int
  var url: String

  var id: String {
    "\(index)-\(url)"
  }
}

private struct RSSPreviewSheet: View {
  @EnvironmentObject private var store: AppStore
  var site: SiteInfo
  var message: String?
  var ok: Bool?
  var results: [SearchResult]
  var categories: [String]
  var page: Int
  var pageSize: Int
  var totalPages: Int
  var hasPrevious: Bool
  var hasNext: Bool
  var elapsedMs: Int?
  @Binding var keyword: String
  @Binding var category: String
  var isLoading: Bool
  var refresh: () -> Void
  var previousPage: () -> Void
  var nextPage: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("RSS 预览")
            .font(.title3.weight(.semibold))
          Text(site.label)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .font(.title3)
        .foregroundStyle(.secondary)
      }
      .padding(18)

      Divider()

      VStack(spacing: 12) {
        HStack(spacing: 10) {
          TextField("搜索标题、副标题或分类", text: $keyword)
            .textFieldStyle(.roundedBorder)
            .onSubmit(refresh)
          Picker("资源分类", selection: $category) {
            Text("全部分类").tag("")
            ForEach(categories, id: \.self) { value in
              Text(value).tag(value)
            }
          }
          .frame(width: 220)
          Button {
            refresh()
          } label: {
            Label(isLoading ? "读取中..." : "搜索", systemImage: "magnifyingglass")
          }
          .disabled(isLoading)
        }
        if let message {
          HStack(spacing: 8) {
            Label(message, systemImage: ok == false ? "exclamationmark.triangle" : "checkmark.circle")
              .foregroundStyle(ok == false ? .orange : .secondary)
            Spacer()
            if isLoading {
              ProgressView()
                .controlSize(.small)
            }
          }
          .font(.caption)
          .frame(maxWidth: .infinity, alignment: .leading)
          .lineLimit(2)
        }
      }
      .padding(18)

      if results.isEmpty {
        ContentUnavailableView(
          ok == false ? "RSS 预览失败" : "暂无 RSS 资源",
          systemImage: ok == false ? "exclamationmark.triangle" : "dot.radiowaves.left.and.right",
          description: Text(ok == false ? (message ?? "请检查站点认证或 RSS 配置。") : "调整关键词或分类后重新搜索。")
        )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(results) { result in
          PTRSSPreviewRow(result: result)
            .environmentObject(store)
        }
        .listStyle(.plain)
      }

      Divider()

      HStack(spacing: 12) {
        Text(pageSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          previousPage()
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.borderless)
        .disabled(isLoading || !hasPrevious)
        Button {
          nextPage()
        } label: {
          Image(systemName: "chevron.right")
        }
        .buttonStyle(.borderless)
        .disabled(isLoading || !hasNext)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
    }
    .frame(minWidth: 980, minHeight: 680)
  }

  private var pageSummary: String {
    let totalText = totalPages > 0 ? "\(page)/\(totalPages)" : "0/0"
    let elapsedText = elapsedMs.map { " · \($0)ms" } ?? ""
    return "第 \(totalText) 页 · \(pageSize) 条/页\(elapsedText)"
  }
}

private struct PTRSSPreviewRow: View {
  @EnvironmentObject private var store: AppStore
  var result: SearchResult

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(result.title)
            .font(.headline)
            .lineLimit(2)
          PTFreeBadge(result: result)
          if result.isPinned == true { PTInfoPill(text: "置顶") }
          if result.isDownloaded == true { PTInfoPill(text: "已下载") }
        }
        if let subtitle = result.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty, subtitle != result.title {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        if result.source != "soulvoice",
           let description = result.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty,
           description != result.title,
           description != result.subtitle {
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary.opacity(0.86))
            .lineLimit(2)
        }
        HStack(spacing: 6) {
          PTInfoPill(text: store.siteLabel(for: result.source))
          if let category = result.category, isReadableMetadataPill(category) { PTInfoPill(text: category) }
          if let language = result.language, isReadableMetadataPill(language) { PTInfoPill(text: language) }
          if let size = result.size { PTInfoPill(text: size) }
          if let publishedAt = result.publishedAt { PTInfoPill(text: publishedAt) }
        }
      }

      Spacer(minLength: 20)

      HStack(spacing: 16) {
        PTMetric(value: result.seeders, label: "做种")
        PTMetric(value: result.leechers, label: "下载")
        PTMetric(value: result.downloads, label: "完成")
      }
      .frame(width: 190, alignment: .trailing)
    }
    .padding(.vertical, 8)
  }

  private func isReadableMetadataPill(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.range(of: #"^\d+$"#, options: .regularExpression) == nil
  }
}

private struct PTFreeBadge: View {
  var result: SearchResult

  private var label: String? {
    if let discount = result.discountLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !discount.isEmpty {
      if let remaining = result.freeRemaining?.trimmingCharacters(in: .whitespacesAndNewlines), !remaining.isEmpty, discount.uppercased() == "FREE" {
        return "\(discount) \(remaining)"
      }
      return discount
    }
    if result.isFree == true {
      if let remaining = result.freeRemaining?.trimmingCharacters(in: .whitespacesAndNewlines), !remaining.isEmpty {
        return "FREE \(remaining)"
      }
      return "FREE"
    }
    return nil
  }

  private var color: Color {
    label?.uppercased().contains("FREE") == true ? .green : .orange
  }

  var body: some View {
    if let label {
      Text(label)
        .font(.caption.weight(.bold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
  }
}

private struct PTInfoPill: View {
  var text: String

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(.quaternary, in: Capsule())
  }
}

private struct PTMetric: View {
  var value: Int?
  var label: String

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(value.map(String.init) ?? "—")
        .font(.caption.monospacedDigit())
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

private struct GlobalEpisodeParseRuleRow: View {
  @Binding var rule: EpisodeParseRule
  var moveUp: () -> Void
  var moveDown: () -> Void
  var remove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Toggle("", isOn: $rule.enabled)
          .labelsHidden()
        FormField(label: "规则名称") {
          TextField("", text: $rule.name, prompt: Text("例如：星号单集规则"))
            .accessibilityLabel("规则名称")
        }
        Button(action: moveUp) {
          Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        .frame(width: 28)
        .help("上移")
        Button(action: moveDown) {
          Image(systemName: "chevron.down")
        }
        .buttonStyle(.borderless)
        .frame(width: 28)
        .help("下移")
        Button(role: .destructive, action: remove) {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .frame(width: 28)
        .help("删除规则")
      }

      FormField(label: "识别表达式") {
        TextField("", text: $rule.pattern, prompt: Text("例如：★(?<episode>\\d{1,3})★"))
          .font(.caption.monospaced())
          .accessibilityLabel("识别表达式")
      }

      DisclosureGroup("高级捕获组") {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
          GridRow {
            Text("单集")
            TextField("episode", text: $rule.episodeGroup)
          }
          GridRow {
            Text("合集开始")
            TextField("start", text: $rule.startGroup)
          }
          GridRow {
            Text("合集结束")
            TextField("end", text: $rule.endGroup)
          }
          GridRow {
            Text("完结标记")
            TextField("final", text: $rule.finalGroup)
          }
        }
        .font(.caption)
        .padding(.top, 6)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 8)
  }
}

private struct OrganizeTargetSettingsRow: View {
  @EnvironmentObject private var store: AppStore
  @State private var confirmDelete = false
  var target: OrganizeTarget
  var edit: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: target.enabled ? "folder" : "folder.badge.minus")
        .foregroundStyle(target.enabled ? .blue : .secondary)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(target.name)
            .font(.body.weight(.medium))
          if target.isDefault {
            Text("默认")
              .font(.caption)
              .foregroundStyle(.green)
          }
          if !target.enabled {
            Text("停用")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(target.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(target.mediaType)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        Task { await store.validateOrganizeTarget(target) }
      } label: {
        Label("检查", systemImage: "checkmark.seal")
      }
      .disabled(store.isLoading)

      Button {
        edit()
      } label: {
        Label("编辑", systemImage: "pencil")
      }
      .disabled(store.isLoading)

      Button {
        Task { await store.setDefaultOrganizeTarget(target) }
      } label: {
        Label("默认", systemImage: "star")
      }
      .disabled(store.isLoading || target.isDefault)

      Button(role: .destructive) {
        confirmDelete = true
      } label: {
        Label("删除", systemImage: "trash")
      }
      .disabled(store.isLoading)
    }
    .alert("删除整理目标？", isPresented: $confirmDelete) {
      Button("取消", role: .cancel) {}
      Button("删除", role: .destructive) {
        Task { await store.deleteOrganizeTarget(target) }
      }
    } message: {
      Text("只会删除“\(target.name)”这条本地配置，不会删除真实文件或媒体库目录。")
    }
  }
}

private struct OrganizeTargetFormSheet: View {
  @EnvironmentObject private var store: AppStore
  var chooseFolder: () -> Void
  var close: () -> Void

  private var isEditing: Bool {
    store.editingOrganizeTargetID != nil
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text(isEditing ? "编辑整理目标" : "新增整理目标")
            .font(.title3.weight(.semibold))
          Text("添加一个媒体库目录，用于整理下载完成的文件。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding([.horizontal, .top], 22)
      .padding(.bottom, 10)

      Divider()

      Form {
        LabeledTextField(label: "显示名称", placeholder: "例如：动画库", text: $store.organizeTargetName, help: "用于在订阅和整理时识别这个目标。")
        FormField(label: "实际路径", help: "请选择媒体库目录。长路径可悬停查看完整内容。") {
          HStack(spacing: 8) {
            TextField("", text: $store.organizeTargetPath, prompt: Text("例如：/Users/me/Movies/Anime"))
              .help(store.organizeTargetPath)
              .accessibilityLabel("实际路径")
            Button {
              chooseFolder()
            } label: {
              Label("选择文件夹", systemImage: "folder")
            }
            .disabled(store.isLoading)
            .help("用 macOS 文件夹选择器填入整理目标路径")
          }
        }
        LabeledTextField(label: "用途说明", placeholder: "例如：TV 动画、剧场版、测试目录", text: $store.organizeTargetMediaType)
        Toggle("设为默认目标", isOn: $store.organizeTargetIsDefault)
        Toggle("启用", isOn: $store.organizeTargetEnabled)

        if let validation = store.lastOrganizeTargetValidation {
          Label(validation.message, systemImage: validation.ok ? "checkmark.circle" : "exclamationmark.triangle")
            .foregroundStyle(validation.ok ? .green : .orange)
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Button("取消", role: .cancel) {
          store.cancelOrganizeTargetEditing()
          close()
        }
        Spacer()
        Button {
          Task {
            if await store.saveOrganizeTargetForm() {
              close()
            }
          }
        } label: {
          Label(isEditing ? "保存目标" : "添加目标", systemImage: "folder.badge.plus")
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isLoading || store.organizeTargetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.organizeTargetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding()
    }
    .frame(minWidth: 560, idealWidth: 620, minHeight: 420)
  }
}

private struct PlaylistServerSettingsSections: View {
  @EnvironmentObject private var store: AppStore
  @State private var serverURL = ""
  @State private var token = ""
  @State private var cdnURL = "https://unpkg.com/bangumi-data@0.3/dist/data.json"
  @State private var selectedLibraryID = ""
  @State private var savedSettings: PlaylistSettingsResponse?
  @State private var libraries: [PlexLibrary] = []
  @State private var statusText = "尚未检测"
  @State private var isWorking = false
  @State private var clearToken = false

  var body: some View {
    Section("Plex Server") {
      LabeledTextField(
        label: "服务器地址",
        placeholder: "例如：http://127.0.0.1:32400",
        text: $serverURL,
        help: "连接由 Kisetsu 后端发起，请填写后端电脑能够访问的地址。"
      )
      LabeledSecureField(
        label: "Token",
        placeholder: savedSettings?.tokenConfigured == true ? "已保存，留空保持不变" : "输入 Plex Token",
        text: $token,
        reference: CredentialReference(scope: "playlist_settings", field: "token")
      )

      if !libraries.isEmpty || !selectedLibraryID.isEmpty {
        LabeledContent("动画媒体库") {
          Picker("动画媒体库", selection: $selectedLibraryID) {
            if selectedLibraryID.isEmpty {
              Text("请选择").tag("")
            }
            ForEach(libraries.filter { $0.type == "show" }) { library in
              Text(library.title).tag(library.id)
            }
            if let savedSettings,
               let id = savedSettings.libraryId,
               !id.isEmpty,
               !libraries.contains(where: { $0.id == id }) {
              Text(savedSettings.libraryTitle ?? "原媒体库").tag(id)
            }
          }
          .labelsHidden()
          .frame(width: 260)
        }
      }

      if savedSettings?.tokenConfigured == true {
        Toggle("清除已保存 Token", isOn: $clearToken)
          .tint(.red)
      }

      HStack(spacing: 10) {
        Button {
          Task { await save() }
        } label: {
          Label("保存设置", systemImage: "square.and.arrow.down")
        }
        .disabled(isWorking || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button {
          Task { await saveAndTest() }
        } label: {
          if isWorking {
            ProgressView()
              .controlSize(.small)
          } else {
            Label("保存并检测", systemImage: "checkmark.seal")
          }
        }
        .disabled(isWorking || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      Label(statusText, systemImage: statusText.contains("正常") ? "checkmark.circle.fill" : "info.circle")
        .foregroundStyle(statusText.contains("正常") ? .green : .secondary)
    }

    Section("季度数据") {
      LabeledTextField(
        label: "bangumi-data CDN",
        placeholder: "https://unpkg.com/bangumi-data@0.3/dist/data.json",
        text: $cdnURL,
        help: "仅支持 HTTP 或 HTTPS 地址。季度数据由后端缓存。"
      )
      Text("番组数据来源：bangumi-data（CC BY 4.0）")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .task(id: store.backendURL) {
      await load()
    }
  }

  private func load() async {
    do {
      let settings = try await store.client.playlistSettings()
      savedSettings = settings
      serverURL = settings.serverUrl
      cdnURL = settings.cdnUrl
      selectedLibraryID = settings.libraryId ?? ""
      statusText = settings.tokenConfigured ? "配置已保存，等待连接检测" : "尚未配置 Plex Token"
    } catch is CancellationError {
      return
    } catch {
      statusText = error.localizedDescription
    }
  }

  @discardableResult
  private func save() async -> Bool {
    isWorking = true
    defer { isWorking = false }
    do {
      let response = try await store.client.savePlaylistSettings(
        PlaylistSettingsUpdate(
          serverUrl: serverURL,
          token: token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : token,
          clearToken: clearToken,
          libraryId: selectedLibraryID.isEmpty ? nil : selectedLibraryID,
          cdnUrl: cdnURL
        )
      )
      savedSettings = response
      token = ""
      clearToken = false
      statusText = "播放列表设置已保存"
      return true
    } catch {
      statusText = error.localizedDescription
      return false
    }
  }

  private func saveAndTest() async {
    guard await save() else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      let response = try await store.client.testPlaylistPlexConnection()
      libraries = response.libraries
      statusText = response.version.map { "Plex Server \($0) 连接正常" } ?? response.message
    } catch {
      statusText = error.localizedDescription
    }
  }
}
