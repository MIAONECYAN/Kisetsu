import SwiftUI

enum MobileSettingsDestination: String, CaseIterable, Identifiable {
  case backend
  case downloaders
  case organize
  case metadata
  case notifications
  case ai
  case episodeRules
  case playlists

  var id: String { rawValue }
  var title: String {
    switch self {
    case .backend: "后端"
    case .downloaders: "下载器"
    case .organize: "整理"
    case .metadata: "元数据"
    case .notifications: "通知"
    case .ai: "AI 辅助分析"
    case .episodeRules: "集数识别"
    case .playlists: "播放列表服务器"
    }
  }
  var subtitle: String {
    switch self {
    case .backend: "连接地址与健康状态"
    case .downloaders: "qBittorrent、Transmission 与任务路由"
    case .organize: "默认整理策略、做种规则与目标目录"
    case .metadata: "TMDB 识别服务"
    case .notifications: "Bark 与事件通知"
    case .ai: "Provider、模型与智能订阅"
    case .episodeRules: "全局自定义集数解析规则"
    case .playlists: "Plex Server 与季度数据源"
    }
  }
  var systemImage: String {
    switch self {
    case .backend: "server.rack"
    case .downloaders: "arrow.down.circle"
    case .organize: "folder.badge.gearshape"
    case .metadata: "film.stack"
    case .notifications: "bell.badge"
    case .ai: "sparkles"
    case .episodeRules: "number.circle"
    case .playlists: "rectangle.stack.badge.play"
    }
  }
}

struct MobileBackendSettingsView: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    Form {
      Section("连接") {
        MobileFormTextField(
          label: "后端地址",
          prompt: "例如：http://192.168.1.10:8000",
          text: $store.backendURLDraft
        )
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
          .autocorrectionDisabled()
        MobileFormValidationMessage(message: backendURLValidationMessage)
        LabeledContent("状态", value: store.healthText)
        Text(store.backendConnectionDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
        if let checked = store.backendLastCheckedAt {
          LabeledContent("最近检测", value: checked.formatted(date: .omitted, time: .shortened))
        }
        Button("保存并检测", systemImage: "checkmark.seal") { Task { await store.checkHealth() } }
          .disabled(store.isLoading || backendURLValidationMessage != nil)
      }
      Section {
        Text("局域网地址必须能从 iPhone 访问。敏感配置由后端保存，不会复制到 iPhone。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .mobileStatusNavigationTitle("后端")
    .task {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      await store.checkHealth()
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

private enum MobileDownloaderPage: String, CaseIterable, Identifiable {
  case routing
  case qbittorrent
  case transmission
  var id: String { rawValue }
  var title: String {
    switch self {
    case .routing: "用途"
    case .qbittorrent: "qBittorrent"
    case .transmission: "Transmission"
    }
  }
}

struct MobileDownloaderSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var page = MobileDownloaderPage.routing
  @State private var qbDownloadMB = ""
  @State private var qbUploadMB = ""
  @State private var trDownloadMB = ""
  @State private var trUploadMB = ""

  var body: some View {
    Form {
      Section {
        Picker("下载器设置", selection: $page) {
          ForEach(MobileDownloaderPage.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }

      switch page {
      case .routing: routingForm
      case .qbittorrent: qbittorrentForm
      case .transmission: transmissionForm
      }
    }
    .mobileStatusNavigationTitle("下载器")
    .task {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else {
        syncLimitDrafts()
        return
      }
      await store.loadDownloaderSettings()
      syncLimitDrafts()
    }
  }

  private var routingForm: some View {
    Group {
      Section("任务用途") {
        downloaderPicker("订阅下载器", selection: $store.downloaderRouting.subscriptionDownloader)
        downloaderPicker("站点刷流下载器", selection: $store.downloaderRouting.brushDownloader)
        downloaderPicker("手动下载器", selection: $store.downloaderRouting.manualDownloader)
        Button("保存用途", systemImage: "square.and.arrow.down") { Task { await store.saveDownloaderRouting() } }
      }
      Section("连接状态") {
        ForEach(store.downloaderStatuses) { status in
          LabeledContent(status.downloader.capitalized) {
            Label(status.message, systemImage: status.verified ? "checkmark.circle.fill" : "info.circle")
              .foregroundStyle(status.verified ? .green : .secondary)
          }
        }
        Button("测试全部", systemImage: "bolt.horizontal") { Task { await store.testAllDownloaders() } }
      }
    }
  }

  private var qbittorrentForm: some View {
    Group {
      Section("连接") {
        MobileFormTextField(label: "Web UI 地址", prompt: "例如：http://192.168.1.10:8080", text: $store.qbittorrent.baseUrl)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
        MobileFormValidationMessage(message: qbittorrentURLValidationMessage)
        MobileFormTextField(label: "用户名", prompt: "下载器登录用户名", text: $store.qbittorrent.username)
        MobileFormSecureField(
          label: "密码",
          prompt: store.qbittorrent.passwordConfigured ? "已保存，留空保持" : "输入登录密码",
          text: $store.qbittorrent.password,
          reference: CredentialReference(scope: "qbittorrent", field: "password")
        )
        MobileFormTextField(label: "默认保存路径", prompt: "留空使用下载器默认目录", text: optionalBinding($store.qbittorrent.defaultSavePath))
        MobileFormTextField(label: "默认分类", prompt: "例如：anime", text: optionalBinding($store.qbittorrent.defaultCategory))
        MobileFormTextField(label: "默认标签", prompt: "多个标签用逗号分隔", text: qbTagsBinding)
        LabeledContent("状态", value: store.qbittorrentConnectionText)
        HStack {
          Button("保存", systemImage: "square.and.arrow.down") { Task { await store.saveQbittorrentConfig() } }
          Button("测试", systemImage: "bolt.horizontal") { Task { await store.testQbittorrent() } }
        }
        .disabled(qbittorrentURLValidationMessage != nil)
      }
      speedLimitSection(name: "qBittorrent", download: $qbDownloadMB, upload: $qbUploadMB) {
        guard
          let downloadLimit = MobileSpeedLimitDraft.bytesPerSecond(qbDownloadMB),
          let uploadLimit = MobileSpeedLimitDraft.bytesPerSecond(qbUploadMB)
        else { return }
        Task {
          await store.saveQBittorrentGlobalLimits(
            QbittorrentGlobalLimits(downloadLimit: downloadLimit, uploadLimit: uploadLimit)
          )
        }
      }
    }
  }

  private var transmissionForm: some View {
    Group {
      Section("连接") {
        MobileFormTextField(label: "RPC 地址", prompt: "例如：http://192.168.1.10:9091", text: $store.transmission.baseUrl)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
        MobileFormValidationMessage(message: transmissionURLValidationMessage)
        MobileFormTextField(label: "用户名", prompt: "下载器登录用户名", text: $store.transmission.username)
        MobileFormSecureField(
          label: "密码",
          prompt: store.transmission.passwordConfigured ? "已保存，留空保持" : "输入登录密码",
          text: $store.transmission.password,
          reference: CredentialReference(scope: "transmission", field: "password")
        )
        MobileFormTextField(label: "默认保存路径", prompt: "留空使用下载器默认目录", text: optionalBinding($store.transmission.defaultSavePath))
        MobileFormTextField(label: "默认标签", prompt: "多个标签用逗号分隔", text: transmissionLabelsBinding)
        LabeledContent("状态", value: store.transmissionConnectionText)
        HStack {
          Button("保存", systemImage: "square.and.arrow.down") { Task { await store.saveTransmissionConfig() } }
          Button("测试", systemImage: "bolt.horizontal") { Task { await store.testTransmission() } }
        }
        .disabled(transmissionURLValidationMessage != nil)
      }
      speedLimitSection(name: "Transmission", download: $trDownloadMB, upload: $trUploadMB) {
        guard
          let downloadLimit = MobileSpeedLimitDraft.bytesPerSecond(trDownloadMB),
          let uploadLimit = MobileSpeedLimitDraft.bytesPerSecond(trUploadMB)
        else { return }
        Task {
          await store.saveTransmissionGlobalLimits(
            QbittorrentGlobalLimits(downloadLimit: downloadLimit, uploadLimit: uploadLimit)
          )
        }
      }
    }
  }

  private func downloaderPicker(_ title: String, selection: Binding<String>) -> some View {
    Picker(title, selection: selection) {
      Text("qBittorrent").tag("qbittorrent")
      Text("Transmission").tag("transmission")
    }
  }

  private var qbittorrentURLValidationMessage: String? {
    MobileFormValidation.httpURLMessage(store.qbittorrent.baseUrl, field: "Web UI 地址")
  }

  private var transmissionURLValidationMessage: String? {
    MobileFormValidation.httpURLMessage(store.transmission.baseUrl, field: "RPC 地址")
  }

  private func speedLimitSection(
    name: String,
    download: Binding<String>,
    upload: Binding<String>,
    save: @escaping () -> Void
  ) -> some View {
    let validationMessage = MobileSpeedLimitDraft.validationMessage(
      download: download.wrappedValue,
      upload: upload.wrappedValue
    )
    return Section {
      MobileFormTextField(label: "全局下载上限", prompt: "例如：20", text: download)
        .keyboardType(.decimalPad)
      MobileFormTextField(label: "全局上传上限", prompt: "例如：5", text: upload)
        .keyboardType(.decimalPad)
      if let validationMessage {
        Text(validationMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }
      Button("应用 \(name) 全局限速", systemImage: "gauge.with.dots.needle.67percent", action: save)
        .disabled(validationMessage != nil)
    } header: {
      Text("\(name) 全局限速")
    } footer: {
      Text("单位为 MB/s。0 或留空表示不限速；设置会作用于 \(name) 中的全部任务。")
    }
  }

  private func optionalBinding(_ binding: Binding<String?>) -> Binding<String> {
    Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
  }

  private var qbTagsBinding: Binding<String> {
    Binding(
      get: { store.qbittorrent.defaultTags.joined(separator: ", ") },
      set: { store.qbittorrent.defaultTags = splitComma($0) }
    )
  }

  private var transmissionLabelsBinding: Binding<String> {
    Binding(
      get: { store.transmission.defaultLabels.joined(separator: ", ") },
      set: { store.transmission.defaultLabels = splitComma($0) }
    )
  }

  private func splitComma(_ value: String) -> [String] {
    value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }

  private func limitText(_ value: Int) -> String {
    guard value > 0 else { return "0" }
    return (Double(value) / 1_048_576).formatted(.number.precision(.fractionLength(0...2)))
  }

  private func syncLimitDrafts() {
    qbDownloadMB = limitText(store.qBittorrentGlobalLimits.downloadLimit)
    qbUploadMB = limitText(store.qBittorrentGlobalLimits.uploadLimit)
    trDownloadMB = limitText(store.transmissionGlobalLimits.downloadLimit)
    trUploadMB = limitText(store.transmissionGlobalLimits.uploadLimit)
  }
}

struct MobileOrganizeSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var showingTargetEditor = false
  @State private var targetToDelete: OrganizeTarget?
  @State private var seedingHoursDraft = ""
  @State private var seedingRatioDraft = ""

  var body: some View {
    Form {
      Section("默认策略") {
        Toggle("新订阅默认自动整理", isOn: $store.organizePolicy.autoOrganizeByDefault)
        Picker("整理后任务处理", selection: Binding(
          get: { store.organizePolicy.postOrganizeAction ?? "remove_task_keep_files" },
          set: { store.setOrganizePolicyAction($0) }
        )) {
          Text("移除任务，保留文件").tag("remove_task_keep_files")
          Text("移除任务和原文件").tag("remove_task_delete_files")
          Text("继续做种").tag("keep_seeding")
          Text("手动处理").tag("manual")
        }
        if store.organizePolicy.postOrganizeAction == "keep_seeding" {
          MobileFormTextField(label: "做种时长（小时）", prompt: "不设置则不按时间停止", text: $seedingHoursDraft)
            .keyboardType(.decimalPad)
          MobileFormValidationMessage(message: seedingHoursValidationMessage)
          MobileFormTextField(label: "目标分享率（%）", prompt: "不设置则不按分享率停止", text: $seedingRatioDraft)
            .keyboardType(.decimalPad)
          MobileFormValidationMessage(message: seedingRatioValidationMessage)
          Picker("停止条件", selection: Binding(
            get: { store.organizePolicy.seedingStopMode ?? "any" },
            set: { store.organizePolicy.seedingStopMode = $0 }
          )) {
            Text("任一条件达到").tag("any")
            Text("全部条件达到").tag("all")
          }
          Picker("达到目标后", selection: Binding(
            get: { store.organizePolicy.postSeedingAction ?? "pause" },
            set: { store.organizePolicy.postSeedingAction = $0 }
          )) {
            Text("暂停任务").tag("pause")
            Text("移除任务，保留文件").tag("remove_task_keep_files")
            Text("移除任务和原文件").tag("remove_task_delete_files")
          }
          if seedingHoursDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
             seedingRatioDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label("未设置停止条件，将持续做种，直到手动处理。", systemImage: "info.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Toggle("清理空下载目录", isOn: Binding(
          get: { store.organizePolicy.cleanEmptyDownloadDirs ?? true },
          set: { store.organizePolicy.cleanEmptyDownloadDirs = $0 }
        ))
        Button("保存整理策略", systemImage: "square.and.arrow.down") {
          applySeedingDrafts()
          Task { await store.saveOrganizePolicy() }
        }
        .disabled(seedingValidationMessage != nil)
      }

      Section("整理目标") {
        ForEach(store.organizeTargets) { target in
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(target.name).font(.headline)
              if target.isDefault { MobileTag(text: "默认", systemImage: "checkmark.circle", tint: .green) }
              Spacer()
              Menu("目标操作", systemImage: "ellipsis.circle") {
                Button("编辑", systemImage: "pencil") {
                  store.editOrganizeTarget(target)
                  showingTargetEditor = true
                }
                Button("检查路径", systemImage: "checkmark.seal") { Task { await store.validateOrganizeTarget(target) } }
                Button("设为默认", systemImage: "star") { Task { await store.setDefaultOrganizeTarget(target) } }
                  .disabled(target.isDefault)
                Button("删除", systemImage: "trash", role: .destructive) { targetToDelete = target }
              }
            }
            Text(target.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
          }
        }
        Button("添加整理目标", systemImage: "plus") {
          store.cancelOrganizeTargetEditing()
          showingTargetEditor = true
        }
      }
    }
    .mobileStatusNavigationTitle("整理")
    .task {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else {
        syncSeedingDrafts()
        return
      }
      await store.loadSettings()
      await store.loadOrganizeTargets()
      syncSeedingDrafts()
    }
    .sheet(isPresented: $showingTargetEditor) {
      MobileOrganizeTargetEditor().environmentObject(store)
    }
    .alert("删除整理目标？", isPresented: Binding(
      get: { targetToDelete != nil },
      set: { if !$0 { targetToDelete = nil } }
    )) {
      Button("删除", role: .destructive) {
        guard let target = targetToDelete else { return }
        Task { await store.deleteOrganizeTarget(target) }
        targetToDelete = nil
      }
      Button("取消", role: .cancel) { targetToDelete = nil }
    } message: {
      Text("不会删除目标目录中的真实媒体文件。")
    }
  }

  private var seedingHoursValidationMessage: String? {
    MobileFormValidation.positiveDecimalMessage(
      seedingHoursDraft,
      field: "做种时长",
      allowsEmpty: true
    )
  }

  private var seedingRatioValidationMessage: String? {
    MobileFormValidation.positiveDecimalMessage(
      seedingRatioDraft,
      field: "目标分享率",
      allowsEmpty: true
    )
  }

  private var seedingValidationMessage: String? {
    guard store.organizePolicy.postOrganizeAction == "keep_seeding" else { return nil }
    return seedingHoursValidationMessage ?? seedingRatioValidationMessage
  }

  private func syncSeedingDrafts() {
    seedingHoursDraft = store.organizePolicy.seedingStopMinutes.map {
      (Double($0) / 60).formatted(.number.precision(.fractionLength(0...2)))
    } ?? ""
    seedingRatioDraft = store.organizePolicy.seedingStopRatio.map {
      ($0 * 100).formatted(.number.precision(.fractionLength(0...2)))
    } ?? ""
  }

  private func applySeedingDrafts() {
    let hours = Double(seedingHoursDraft.replacingOccurrences(of: ",", with: "."))
    let ratio = Double(seedingRatioDraft.replacingOccurrences(of: ",", with: "."))
    store.organizePolicy.seedingStopMinutes = hours.map { max(1, Int(($0 * 60).rounded())) }
    store.organizePolicy.seedingStopRatio = ratio.map { $0 / 100 }
  }
}

private struct MobileOrganizeTargetEditor: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var saving = false

  var body: some View {
    NavigationStack {
      Form {
        MobileFormTextField(label: "显示名称", prompt: "例如：动画媒体库", text: $store.organizeTargetName)
        MobileFormTextField(label: "后端目录路径", prompt: "例如：/media/anime", text: $store.organizeTargetPath)
          .textInputAutocapitalization(.never)
        Picker("媒体类型", selection: $store.organizeTargetMediaType) {
          Text("动画").tag("anime")
          Text("电视剧").tag("tv")
          Text("电影").tag("movie")
        }
        Toggle("设为默认", isOn: $store.organizeTargetIsDefault)
        Toggle("启用", isOn: $store.organizeTargetEnabled)
      }
      .mobileStatusNavigationTitle(store.editingOrganizeTargetID == nil ? "添加整理目标" : "编辑整理目标")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { store.cancelOrganizeTargetEditing(); dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            Task {
              saving = true
              let saved = await store.saveOrganizeTargetForm()
              saving = false
              if saved { dismiss() }
            }
          }
          .disabled(saving || store.organizeTargetName.isEmpty || store.organizeTargetPath.isEmpty)
        }
      }
    }
    .interactiveDismissDisabled(saving)
  }
}

struct MobileMetadataSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var clearing = false

  var body: some View {
    Form {
      Section("TMDB") {
        LabeledContent("状态", value: store.metadataSettings.message)
        MobileFormSecureField(
          label: "TMDB API Key",
          prompt: store.metadataSettings.tmdbApiKeyConfigured ? "输入新值，留空保持" : "输入 API Key",
          text: $store.tmdbAPIKeyInput,
          reference: CredentialReference(scope: "metadata", field: "tmdb_api_key")
        )
        HStack {
          Button("保存", systemImage: "square.and.arrow.down") { Task { _ = await store.saveMetadataSettings() } }
          Button("测试", systemImage: "checkmark.seal") { Task { await store.testTMDBSettings() } }
        }
        LabeledContent("最近测试", value: store.tmdbTestText)
        Button("清除 API Key", systemImage: "trash", role: .destructive) { clearing = true }
          .disabled(!store.metadataSettings.tmdbApiKeyConfigured)
      }
    }
    .mobileStatusNavigationTitle("元数据")
    .task {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      await store.loadSettings()
    }
    .alert("清除 TMDB API Key？", isPresented: $clearing) {
      Button("清除", role: .destructive) { Task { _ = await store.clearTMDBSettings() } }
      Button("取消", role: .cancel) {}
    }
  }
}

struct MobileNotificationSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var clearing = false

  var body: some View {
    Form {
      Section("Bark") {
        Toggle("启用通知", isOn: $store.notificationsEnabled)
        Toggle("启用 Bark", isOn: $store.barkEnabled)
        MobileFormTextField(label: "Bark Server 地址", prompt: "例如：https://api.day.app", text: $store.barkServerURL)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
        MobileFormValidationMessage(message: barkServerValidationMessage)
        MobileFormSecureField(
          label: "Device Key",
          prompt: store.notificationSettings.bark.hasDeviceKey ? "输入新值，留空保持" : "输入 Device Key",
          text: $store.barkDeviceKeyInput,
          reference: CredentialReference(scope: "notifications", field: "device_key")
        )
        MobileFormTextField(label: "通知分组", prompt: "例如：Kisetsu", text: $store.barkGroup)
        MobileFormTextField(label: "通知铃声", prompt: "留空使用 Bark 默认铃声", text: $store.barkSound)
        MobileFormTextField(label: "通知图标 URL", prompt: "留空优先使用海报", text: $store.barkIcon)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
        MobileFormValidationMessage(message: barkIconValidationMessage)
        Picker("通知级别", selection: $store.barkLevel) {
          Text("活跃").tag("active")
          Text("时效").tag("timeSensitive")
          Text("被动").tag("passive")
        }
        Toggle("自动复制", isOn: $store.barkAutoCopy)
      }
      Section("通知事件") {
        Toggle("订阅刷新", isOn: $store.notifySubscription)
        Toggle("新增下载任务", isOn: $store.notifyDownload)
        Toggle("整理结果", isOn: $store.notifyOrganize)
      }
      Section {
        Button("保存通知设置", systemImage: "square.and.arrow.down") { Task { _ = await store.saveNotificationSettings() } }
        Button("发送测试通知", systemImage: "paperplane") { Task { await store.testNotificationSettings() } }
        LabeledContent("最近测试", value: store.notificationTestText)
        Button("清除 Device Key", systemImage: "trash", role: .destructive) { clearing = true }
          .disabled(!store.notificationSettings.bark.hasDeviceKey)
      }
      .disabled(hasURLValidationError)
    }
    .mobileStatusNavigationTitle("通知")
    .task {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      await store.loadSettings()
    }
    .alert("清除 Bark Device Key？", isPresented: $clearing) {
      Button("清除", role: .destructive) { Task { _ = await store.clearBarkDeviceKey() } }
      Button("取消", role: .cancel) {}
    }
  }

  private var barkServerValidationMessage: String? {
    MobileFormValidation.httpURLMessage(
      store.barkServerURL,
      field: "Bark Server 地址",
      allowsEmpty: !store.barkEnabled
    )
  }

  private var barkIconValidationMessage: String? {
    MobileFormValidation.httpURLMessage(store.barkIcon, field: "通知图标 URL", allowsEmpty: true)
  }

  private var hasURLValidationError: Bool {
    barkServerValidationMessage != nil || barkIconValidationMessage != nil
  }
}

struct MobileAISettingsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var clearing = false

  var body: some View {
    Form {
      Section("服务") {
        Toggle("启用 AI 辅助分析", isOn: $store.aiEnabled)
        Picker("Provider", selection: $store.aiProvider) {
          ForEach(AIProviderCatalog.options) { option in
            Text(option.title).tag(option.id)
          }
        }
        .onChange(of: store.aiProvider) { previousProvider, provider in
          store.switchAIProvider(from: previousProvider, to: provider)
        }
        MobileFormTextField(
          label: "Base URL",
          prompt: AIProviderCatalog.baseURLPlaceholder(for: store.aiProvider),
          text: $store.aiBaseURL
        )
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
        MobileFormValidationMessage(message: baseURLValidationMessage)
        MobileFormSecureField(
          label: "API Key",
          prompt: store.aiSettings.apiKeyConfigured ? "输入新值，留空保持" : "输入 API Key",
          text: $store.aiAPIKeyInput,
          reference: CredentialReference(scope: "ai_settings", field: "api_key", item: store.aiProvider)
        )
        if store.aiModels.isEmpty {
          MobileFormTextField(label: "模型", prompt: AIProviderCatalog.modelPlaceholder(for: store.aiProvider), text: $store.aiModel)
        } else {
          Picker("模型", selection: $store.aiModel) {
            ForEach(store.aiModels) { Text($0.name ?? $0.id).tag($0.id) }
          }
        }
        Toggle("智能订阅时使用 AI", isOn: $store.useAIForSmartSubscription)
      }
      Section {
        Button("获取模型列表", systemImage: "arrow.clockwise") { Task { await store.loadAIModels() } }
        Button("保存 AI 设置", systemImage: "square.and.arrow.down") { Task { _ = await store.saveAISettings() } }
        Button("测试连接", systemImage: "checkmark.seal") { Task { await store.testAISettings() } }
        LabeledContent("状态", value: store.aiSettings.message)
        LabeledContent("最近测试", value: store.aiTestText)
        Button("清除 API Key", systemImage: "trash", role: .destructive) { clearing = true }
          .disabled(!store.aiSettings.apiKeyConfigured)
      }
      .disabled(baseURLValidationMessage != nil)
    }
    .mobileStatusNavigationTitle("AI 辅助分析")
    .task {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      await store.loadSettings()
    }
    .alert("清除 AI API Key？", isPresented: $clearing) {
      Button("清除", role: .destructive) { Task { _ = await store.clearAIAPIKey() } }
      Button("取消", role: .cancel) {}
    }
  }

  private var baseURLValidationMessage: String? {
    MobileFormValidation.httpURLMessage(store.aiBaseURL, field: "Base URL", allowsEmpty: true)
  }
}

struct MobileEpisodeRulesSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var isTesting = false
  @State private var episodeRuleEditorRoute: MobileEpisodeRuleEditorRoute?

  var body: some View {
    Form {
      Section("内置规则") {
        ForEach(store.builtinEpisodeParseRules) { rule in
          Label(rule.name, systemImage: rule.enabled ? "checkmark.circle" : "circle")
        }
      }
      Section("自定义规则") {
        MobileEpisodeRuleManager(
          rules: $store.globalEpisodeParseRules,
          builtinRules: store.builtinEpisodeParseRules,
          testTitle: $store.globalEpisodeRuleTestTitle,
          testResponse: store.lastGlobalEpisodeRuleTestResponse,
          isTesting: isTesting,
          scopeTitle: "全局自定义规则",
          fallbackTitle: "仅使用系统内置规则",
          deleteMessage: "只删除这条全局自定义规则，不影响系统内置规则和订阅专属规则。",
          addTemplate: { store.addGlobalEpisodeParseRule(template: $0) },
          runTest: {
            isTesting = true
            if MobileDebugConfiguration.usesFixturesAtRuntime {
              #if DEBUG
              store.lastGlobalEpisodeRuleTestResponse = MobileDebugFixtureData.episodeRuleTestResponse
              #endif
            } else {
              _ = await store.testGlobalEpisodeParseRules()
            }
            isTesting = false
          },
          presentEditor: { episodeRuleEditorRoute = $0 }
        )
        if hasInvalidRules {
          MobileFormValidationMessage(message: "请先修正无效的集数识别规则。")
        }
        Button("保存全局规则", systemImage: "square.and.arrow.down") { Task { await store.saveGlobalEpisodeRules() } }
          .disabled(hasInvalidRules || MobileDebugConfiguration.usesFixturesAtRuntime)
      }
    }
    .mobileStatusNavigationTitle("集数识别")
    .navigationDestination(item: $episodeRuleEditorRoute) { route in
      MobileEpisodeRuleEditorDestination(route: route) { updated in
        MobileEpisodeRuleCollection.save(updated, to: &store.globalEpisodeParseRules)
      }
      .environmentObject(store)
    }
    .task {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      await store.loadEpisodeRuleSettings()
    }
  }

  private var hasInvalidRules: Bool {
    MobileEpisodeRuleValidation.hasInvalidRules(store.globalEpisodeParseRules, enabled: true)
  }
}

struct MobilePlaylistServerSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var serverURL = ""
  @State private var token = ""
  @State private var cdnURL = "https://unpkg.com/bangumi-data@0.3/dist/data.json"
  @State private var selectedLibraryID = ""
  @State private var saved: PlaylistSettingsResponse?
  @State private var libraries: [PlexLibrary] = []
  @State private var status = "尚未检测"
  @State private var working = false
  @State private var clearToken = false

  var body: some View {
    Form {
      Section("Plex Server") {
        MobileFormTextField(label: "Plex Server 地址", prompt: "例如：http://192.168.1.10:32400", text: $serverURL)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
        MobileFormValidationMessage(message: serverURLValidationMessage)
        MobileFormSecureField(
          label: "Plex Token",
          prompt: saved?.tokenConfigured == true ? "输入新值，留空保持" : "输入 Token",
          text: $token,
          reference: CredentialReference(scope: "playlist_settings", field: "token")
        )
        if !libraries.isEmpty || !selectedLibraryID.isEmpty {
          Picker("动画媒体库", selection: $selectedLibraryID) {
            Text("请选择").tag("")
            ForEach(libraries.filter { $0.type == "show" }) { Text($0.title).tag($0.id) }
          }
        }
        if saved?.tokenConfigured == true { Toggle("清除已保存 Token", isOn: $clearToken).tint(.red) }
        HStack {
          Button("保存", systemImage: "square.and.arrow.down") { Task { _ = await saveSettings() } }
          Button("保存并检测", systemImage: "checkmark.seal") { Task { await saveAndTest() } }
        }
        .disabled(working || playlistSettingsValidationMessage != nil)
        LabeledContent("状态", value: status)
      }
      Section("季度数据") {
        MobileFormTextField(label: "bangumi-data CDN", prompt: "https://unpkg.com/bangumi-data@0.3/dist/data.json", text: $cdnURL)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
        MobileFormValidationMessage(message: cdnURLValidationMessage)
        Text("番组数据来源：bangumi-data（CC BY 4.0），由后端缓存。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .mobileStatusNavigationTitle("播放列表服务器")
    .task {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      await loadSettings()
    }
  }

  private func loadSettings() async {
    do {
      let settings = try await store.client.playlistSettings()
      saved = settings
      serverURL = settings.serverUrl
      cdnURL = settings.cdnUrl
      selectedLibraryID = settings.libraryId ?? ""
      status = settings.tokenConfigured ? "配置已保存，等待连接检测" : "尚未配置 Plex Token"
    } catch is CancellationError {
      return
    } catch {
      status = error.localizedDescription
    }
  }

  @discardableResult
  private func saveSettings() async -> Bool {
    guard playlistSettingsValidationMessage == nil else { return false }
    working = true
    defer { working = false }
    do {
      saved = try await store.client.savePlaylistSettings(
        PlaylistSettingsUpdate(
          serverUrl: serverURL,
          token: token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : token,
          clearToken: clearToken,
          libraryId: selectedLibraryID.isEmpty ? nil : selectedLibraryID,
          cdnUrl: cdnURL
        )
      )
      token = ""
      clearToken = false
      status = "播放列表设置已保存"
      return true
    } catch {
      status = error.localizedDescription
      return false
    }
  }

  private var serverURLValidationMessage: String? {
    MobileFormValidation.httpURLMessage(serverURL, field: "Plex Server 地址")
  }

  private var cdnURLValidationMessage: String? {
    MobileFormValidation.httpURLMessage(cdnURL, field: "bangumi-data CDN")
  }

  private var playlistSettingsValidationMessage: String? {
    serverURLValidationMessage ?? cdnURLValidationMessage
  }

  private func saveAndTest() async {
    guard await saveSettings() else { return }
    working = true
    defer { working = false }
    do {
      let response = try await store.client.testPlaylistPlexConnection()
      libraries = response.libraries
      status = response.version.map { "Plex Server \($0) 连接正常" } ?? response.message
    } catch {
      status = error.localizedDescription
    }
  }
}
