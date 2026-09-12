import SwiftUI

enum MobileBrushTab: String, CaseIterable, Identifiable {
  case overview
  case tasks
  case rules

  var id: String { rawValue }
  var title: String {
    switch self {
    case .overview: "概览"
    case .tasks: "任务"
    case .rules: "规则"
    }
  }
}

enum MobileBrushRuleCategory: String, CaseIterable, Identifiable {
  case general
  case cleanup
  case sites
  case filters
  case advanced

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "常规"
    case .cleanup: "清理"
    case .sites: "站点"
    case .filters: "资源筛选"
    case .advanced: "高级"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .cleanup: "clock.arrow.circlepath"
    case .sites: "antenna.radiowaves.left.and.right"
    case .filters: "line.3.horizontal.decrease.circle"
    case .advanced: "slider.horizontal.3"
    }
  }
}

struct MobileBrushView: View {
  @EnvironmentObject private var store: AppStore
  @State private var tab = MobileBrushTab.overview
  @State private var brushDraft = BrushSettings()
  @State private var showingRunConfirmation = false
  @State private var showingCheckConfirmation = false
  @State private var showingClearConfirmation = false
  @State private var showingRunHistory = false
  @State private var pendingTaskAction: BrushTaskAction?
  @State private var ruleCategory = MobileBrushRuleCategory.general
  @State private var selectedGroupID = ""

  var body: some View {
    VStack(spacing: 0) {
      Picker("刷流页面", selection: $tab) {
        ForEach(MobileBrushTab.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal)
      .padding(.vertical, 10)

      switch tab {
      case .overview: overviewList
      case .tasks: taskList
      case .rules: rulesForm
      }
    }
    .mobileStatusNavigationTitle("站点刷流")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { toolbarContent }
    .task {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      await store.loadBrush(silent: true)
      syncBrushDraft(store.brushSettings)
    }
    .alert("立即运行刷流？", isPresented: $showingRunConfirmation) {
      Button("运行") { Task { await store.runBrushNow() } }
      Button("取消", role: .cancel) {}
    } message: {
      Text("后端会按当前分组和规则检查资源，并可能提交新的下载任务。")
    }
    .alert("立即检查任务？", isPresented: $showingCheckConfirmation) {
      Button("检查") { Task { await store.checkBrushNow() } }
      Button("取消", role: .cancel) {}
    } message: {
      Text("将检查现有刷流任务的状态与清理条件，可能按已保存规则处理任务。")
    }
    .alert("清理已结束的刷流记录？", isPresented: $showingClearConfirmation) {
      Button("清理记录", role: .destructive) { Task { await store.clearBrushRecords() } }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只清理已删除、已归档和异常记录及运行日志，不会删除活动任务或普通下载历史。")
    }
    .alert("确认删除刷流任务？", isPresented: Binding(
      get: { pendingTaskAction != nil },
      set: { if !$0 { pendingTaskAction = nil } }
    )) {
      Button(pendingTaskAction?.deletesFiles == true ? "删除任务和文件" : "删除任务", role: .destructive) {
        guard let action = pendingTaskAction else { return }
        Task { await store.manageBrushTask(action.task, action: action.action) }
        pendingTaskAction = nil
      }
      Button("取消", role: .cancel) { pendingTaskAction = nil }
    } message: {
      Text(pendingTaskAction?.deletesFiles == true
        ? "后端会执行平台对应的安全校验；删除文件不可恢复。"
        : "只从下载器移除任务，保留下载文件。")
    }
    .sheet(isPresented: $showingRunHistory) {
      NavigationStack {
        MobileBrushRunHistoryView()
          .environmentObject(store)
      }
    }
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarTrailing) {
      if tab == .rules {
        Button("保存规则", systemImage: "square.and.arrow.down") {
          Task {
            let runtimeEnabled = store.brushStatus?.enabled ?? brushDraft.enabled
            if await store.saveBrushSettings(brushDraft.preservingRuntimeEnabled(runtimeEnabled)) {
              syncBrushDraft(store.brushSettings)
            }
          }
        }
        .disabled(!hasUnsavedRules || store.isLoading)
      } else {
        Menu("刷流操作", systemImage: "ellipsis.circle") {
          Button("检查任务", systemImage: "checkmark.arrow.trianglehead.counterclockwise") {
            showingCheckConfirmation = true
          }
          Button("立即刷流", systemImage: "bolt.fill") { showingRunConfirmation = true }
            .disabled(store.brushStatus?.enabled != true)
          Divider()
          Button("运行记录", systemImage: "clock.arrow.circlepath") {
            showingRunHistory = true
            Task { await store.refreshBrushRuns() }
          }
          Button("清理已结束记录", systemImage: "eraser", role: .destructive) {
            showingClearConfirmation = true
          }
        }
      }
      Button("刷新", systemImage: "arrow.clockwise") {
        Task {
          await store.loadBrush()
          if tab == .rules { syncBrushDraft(store.brushSettings) }
        }
      }
    }
  }

  private var hasUnsavedRules: Bool {
    !brushDraft.hasSameRuleConfiguration(as: store.brushSettings)
  }

  private var overviewList: some View {
    List {
      if let status = store.brushStatus {
        Section("运行状态") {
          LabeledContent("刷流功能", value: status.enabled ? "已启用" : "已停用")
          LabeledContent("调度器", value: status.schedulerRunning ? "运行中" : "未运行")
          if let operation = status.currentOperation { LabeledContent("当前操作", value: operation) }
          if let next = status.nextBrushAt { LabeledContent("下次获取资源", value: MobileFormat.date(next)) }
          if let next = status.nextCheckAt { LabeledContent("下次检查任务", value: MobileFormat.date(next)) }
          if let error = status.lastError, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
          HStack {
            Button(status.schedulerRunning ? "停止" : "启动", systemImage: status.schedulerRunning ? "stop.fill" : "play.fill") {
              Task {
                if status.schedulerRunning { await store.stopBrush() } else { await store.startBrush() }
              }
            }
            .buttonStyle(.glass)
            Spacer()
            Button("立即刷流", systemImage: "bolt.fill") { showingRunConfirmation = true }
              .buttonStyle(.glass)
              .disabled(!status.enabled)
          }
        }

        Section("任务统计") {
          LabeledContent("活动任务", value: "\(status.stats.activeTasks)")
          LabeledContent("正在下载", value: "\(status.stats.downloadingTasks)")
          LabeledContent("正在做种", value: "\(status.stats.seedingTasks)")
          LabeledContent("刷流占用", value: MobileFormat.bytes(status.stats.occupiedBytes))
        }

        if let transfer = status.downloaderTransfer {
          Section("下载器流量") {
            LabeledContent("下载", value: MobileFormat.bytes(transfer.downloadedBytes))
            LabeledContent("上传", value: MobileFormat.bytes(transfer.uploadedBytes))
            if let ratio = transfer.overallRatio {
              LabeledContent("分享率", value: ratio.formatted(.number.precision(.fractionLength(2))))
            }
            if let error = transfer.error, !error.isEmpty {
              Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
          }
        }
      }

      Section {
        if store.brushSiteAccounts.isEmpty {
          Text("启用刷流站点后显示账户流量").foregroundStyle(.secondary)
        } else {
          ForEach(store.brushSiteAccounts) { account in
            MobileBrushSiteAccountRow(account: account)
          }
        }
      } header: {
        HStack {
          Text("站点账户")
          Spacer()
          Button("刷新站点账户", systemImage: "arrow.clockwise") {
            Task { await store.refreshBrushSiteAccounts() }
          }
          .labelStyle(.iconOnly)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
          .accessibilityLabel("刷新站点账户")
        }
      }
    }
    .refreshable { await store.refreshBrushRuntime() }
  }

  private var taskList: some View {
    List {
      Section {
        Toggle("显示已结束任务", isOn: $store.showArchivedBrushTasks)
          .onChange(of: store.showArchivedBrushTasks) {
            Task { await store.loadBrush(silent: true) }
          }
      }

      Section("任务") {
        if store.brushTasks.isEmpty {
          ContentUnavailableView("暂无刷流任务", systemImage: "arrow.up.arrow.down.circle")
        } else {
          ForEach(store.brushTasks) { task in
            MobileBrushTaskRow(task: task)
              .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button("恢复", systemImage: "play.fill") { Task { await store.manageBrushTask(task, action: "resume") } }.tint(.green)
                Button("暂停", systemImage: "pause.fill") { Task { await store.manageBrushTask(task, action: "pause") } }.tint(.orange)
              }
              .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("删除", systemImage: "trash", role: .destructive) {
                  pendingTaskAction = BrushTaskAction(task: task, action: "delete", deletesFiles: false)
                }
                Button("删文件", systemImage: "trash.slash", role: .destructive) {
                  pendingTaskAction = BrushTaskAction(task: task, action: "delete_files", deletesFiles: true)
                }
              }
              .contextMenu {
                Button("恢复", systemImage: "play.fill") { Task { await store.manageBrushTask(task, action: "resume") } }
                Button("暂停", systemImage: "pause.fill") { Task { await store.manageBrushTask(task, action: "pause") } }
                Divider()
                Button("删除任务", systemImage: "trash", role: .destructive) {
                  pendingTaskAction = BrushTaskAction(task: task, action: "delete", deletesFiles: false)
                }
                Button("删除任务和文件", systemImage: "trash.slash", role: .destructive) {
                  pendingTaskAction = BrushTaskAction(task: task, action: "delete_files", deletesFiles: true)
                }
              }
          }
        }
      }
    }
    .refreshable { await store.refreshBrushRuntime() }
  }

  private var rulesForm: some View {
    Form {
      Section {
        Picker("规则分类", selection: $ruleCategory) {
          ForEach(MobileBrushRuleCategory.allCases) { category in
            Label(category.title, systemImage: category.symbol).tag(category)
          }
        }
        .pickerStyle(.menu)
      }

      selectedRuleSections

      if hasUnsavedRules {
        Section {
          Button("放弃未保存更改", systemImage: "arrow.uturn.backward", role: .destructive) {
            syncBrushDraft(store.brushSettings)
          }
        } footer: {
          Text("修改只保存在当前草稿中，点击右上角保存后才会写入后端。")
        }
      }
    }
  }

  @ViewBuilder
  private var selectedRuleSections: some View {
    switch ruleCategory {
    case .general:
      Section("通知") {
        Toggle("发送 Bark 通知", isOn: $brushDraft.notificationsEnabled)
      }
      Section("目录") {
        LabeledContent("刷流专用目录") {
          TextField("输入目录", text: $brushDraft.savePath)
            .multilineTextAlignment(.trailing)
        }
      }
      Section("调度") {
        Stepper("获取间隔：\(brushDraft.brushIntervalMinutes) 分钟", value: $brushDraft.brushIntervalMinutes, in: 1...1_440)
      }
      Section("运行时段") {
        Toggle("限制运行时段", isOn: activeTimeEnabled)
        if activeTimeEnabled.wrappedValue {
          DatePicker("开始时间", selection: activeTimeBinding($brushDraft.activeTimeStart, fallbackHour: 0), displayedComponents: .hourAndMinute)
          DatePicker("结束时间", selection: activeTimeBinding($brushDraft.activeTimeEnd, fallbackHour: 7), displayedComponents: .hourAndMinute)
        } else {
          LabeledContent("当前时段", value: "全天运行")
        }
      }

    case .cleanup:
      groupSelectionSection
      if let group = selectedGroup {
        Section("当前规则") {
          LabeledContent("清理条件", value: cleanupSummary(group.rule))
          Text("下载完成后，任一条件达成即可清理。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section("达标条件") {
          MobileOptionalDoubleField("做种时间", value: selectedGroupRuleBinding.seedTimeHours, suffix: "小时")
          MobileOptionalDoubleField("分享率", value: ratioPercentBinding(selectedGroupRuleBinding.seedRatio), suffix: "%")
        }
      } else {
        missingGroupSection
      }
      Section("清理行为") {
        Toggle("清理时同时删除刷流文件", isOn: $brushDraft.deleteFilesOnCleanup)
        Toggle("自动隐藏已结束记录", isOn: archiveEnabled)
        if archiveEnabled.wrappedValue {
          MobileOptionalIntField("隐藏等待时间", value: $brushDraft.archiveAfterDays, suffix: "天")
        }
      }

    case .sites:
      Section("分组") {
        ForEach(brushDraft.brushGroups) { group in
          NavigationLink {
            MobileBrushGroupSiteEditor(group: groupBinding(group.id))
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              HStack {
                Text(group.name)
                if !group.enabled { MobileTag(text: "已停用", tint: .secondary) }
              }
              Text("\(group.siteIds.count) 个站点")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .onDelete(perform: deleteGroups)
        Button("新增分组", systemImage: "plus.circle", action: addGroup)
      }
      Section("站点分配") {
        ForEach(brushSites) { site in
          Picker(site.label, selection: siteGroupBinding(site.id)) {
            Text("不参与刷流").tag("")
            ForEach(brushDraft.brushGroups) { group in
              Text(group.name).tag(group.id)
            }
          }
        }
      }

    case .filters:
      groupSelectionSection
      if selectedGroup != nil {
        Section("优惠") {
          Toggle("FREE", isOn: promotionBinding("free"))
          Toggle("双倍上传 FREE", isOn: promotionBinding("2xfree"))
          LabeledContent("当前要求", value: selectedGroupRuleBinding.wrappedValue.promotionSelectionSummary)
        }
        Section("体积") {
          MobileOptionalDoubleField("最小体积", value: selectedGroupRuleBinding.sizeMinGb, suffix: "GB")
          MobileOptionalDoubleField("最大体积", value: selectedGroupRuleBinding.sizeMaxGb, suffix: "GB")
        }
        Section("活跃度") {
          MobileOptionalIntField("最少做种数", value: selectedGroupRuleBinding.seedersMin, suffix: "个")
          MobileOptionalIntField("最多做种数", value: selectedGroupRuleBinding.seedersMax, suffix: "个")
        }
        Section("发布时间") {
          MobileOptionalIntField("发布至少经过", value: selectedGroupRuleBinding.publishAgeMinMinutes, suffix: "分钟")
          MobileOptionalIntField("仅获取最近", value: selectedGroupRuleBinding.publishAgeMaxMinutes, suffix: "分钟")
        }
        Section("关键词") {
          MobileFormTextField(
            label: "包含正则",
            prompt: "留空表示不限制包含内容",
            text: optionalText(selectedGroupRuleBinding.includePattern)
          )
          MobileFormTextField(
            label: "排除正则",
            prompt: "留空表示不排除标题内容",
            text: optionalText(selectedGroupRuleBinding.excludePattern)
          )
          Toggle("排除现有订阅相关资源", isOn: selectedGroupBinding.excludeSubscriptions)
        }
      } else {
        missingGroupSection
      }

    case .advanced:
      Section("共享容量") {
        MobileOptionalDoubleField("最大刷流占用", value: $brushDraft.maxStorageGb, suffix: "GB")
      }
      groupSelectionSection
      if selectedGroup != nil {
        Section("分组容量") {
          MobileOptionalIntField("最大任务数", value: selectedGroupBinding.maxTasks, suffix: "个")
          MobileOptionalIntField("最大同时下载数", value: selectedGroupBinding.maxDownloading, suffix: "个")
        }
        Section("单轮任务") {
          Stepper("最多新增：\(selectedGroupBinding.wrappedValue.maxAdditionsPerRun) 条", value: selectedGroupBinding.maxAdditionsPerRun, in: 1...100)
          Stepper("每站读取：\(selectedGroupBinding.wrappedValue.candidatesPerSite) 条", value: selectedGroupBinding.candidatesPerSite, in: 1...100)
        }
        Section("下载行为") {
          Toggle("优先下载首尾块", isOn: selectedGroupBinding.firstLastPiecePriority)
          Toggle("使用下载器自动管理", isOn: selectedGroupBinding.automaticCategory)
        }
      } else {
        missingGroupSection
      }
    }
  }

  private var brushSites: [SiteInfo] {
    store.sites.filter { $0.supportsBrush == true && $0.enabled != false }
  }

  private var selectedGroup: BrushGroup? {
    brushDraft.brushGroups.first { $0.id == selectedGroupID }
  }

  private var selectedGroupBinding: Binding<BrushGroup> {
    groupBinding(selectedGroupID)
  }

  private var selectedGroupRuleBinding: Binding<BrushRule> {
    selectedGroupBinding.rule
  }

  private func optionalText(_ value: Binding<String?>) -> Binding<String> {
    Binding(
      get: { value.wrappedValue ?? "" },
      set: {
        let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        value.wrappedValue = trimmed.isEmpty ? nil : trimmed
      }
    )
  }

  private func groupBinding(_ groupID: String) -> Binding<BrushGroup> {
    Binding(
      get: {
        brushDraft.brushGroups.first { $0.id == groupID }
          ?? brushDraft.brushGroups.first
          ?? BrushGroup(id: "default", name: "默认分组")
      },
      set: { updated in
        var groups = brushDraft.brushGroups
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index] = updated
        brushDraft.brushGroups = groups
      }
    )
  }

  private func siteGroupBinding(_ siteID: String) -> Binding<String> {
    Binding {
      brushDraft.brushGroups.first(where: { $0.siteIds.contains(siteID) })?.id ?? ""
    } set: { groupID in
      var groups = brushDraft.brushGroups
      for index in groups.indices {
        groups[index].siteIds.removeAll { $0 == siteID }
      }
      if let index = groups.firstIndex(where: { $0.id == groupID }) {
        groups[index].siteIds.append(siteID)
      }
      brushDraft.brushGroups = groups
    }
  }

  private var groupSelectionSection: some View {
    Section("编辑分组") {
      Picker("分组", selection: $selectedGroupID) {
        ForEach(brushDraft.brushGroups) { group in
          Text(group.name).tag(group.id)
        }
      }
      .pickerStyle(.menu)
    }
  }

  private var missingGroupSection: some View {
    Section {
      Label("请先在“站点”中建立刷流分组。", systemImage: "square.stack.3d.up")
        .foregroundStyle(.secondary)
    }
  }

  private func promotionBinding(_ mode: String) -> Binding<Bool> {
    Binding(
      get: { selectedGroupRuleBinding.wrappedValue.effectivePromotionModes.contains(mode) },
      set: { enabled in
        var rule = selectedGroupRuleBinding.wrappedValue
        rule.setPromotionSelection(mode, enabled: enabled)
        selectedGroupRuleBinding.wrappedValue = rule
      }
    )
  }

  private var activeTimeEnabled: Binding<Bool> {
    Binding {
      brushDraft.activeTimeStart != nil && brushDraft.activeTimeEnd != nil
    } set: { enabled in
      if enabled {
        brushDraft.activeTimeStart = brushDraft.activeTimeStart ?? "00:00"
        brushDraft.activeTimeEnd = brushDraft.activeTimeEnd ?? "07:00"
      } else {
        brushDraft.activeTimeStart = nil
        brushDraft.activeTimeEnd = nil
      }
    }
  }

  private func activeTimeBinding(_ binding: Binding<String?>, fallbackHour: Int) -> Binding<Date> {
    Binding {
      let parts = binding.wrappedValue?.split(separator: ":").compactMap { Int($0) } ?? []
      let hour = parts.count == 2 ? parts[0] : fallbackHour
      let minute = parts.count == 2 ? parts[1] : 0
      return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    } set: { date in
      let components = Calendar.current.dateComponents([.hour, .minute], from: date)
      binding.wrappedValue = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
  }

  private var archiveEnabled: Binding<Bool> {
    Binding {
      brushDraft.archiveAfterDays != nil
    } set: { enabled in
      brushDraft.archiveAfterDays = enabled ? (brushDraft.archiveAfterDays ?? 30) : nil
    }
  }

  private func ratioPercentBinding(_ binding: Binding<Double?>) -> Binding<Double?> {
    Binding(
      get: { binding.wrappedValue.map { $0 * 100 } },
      set: { binding.wrappedValue = $0.map { max(0, $0) / 100 } }
    )
  }

  private func cleanupSummary(_ rule: BrushRule) -> String {
    let hours = rule.seedTimeHours ?? 72
    let ratio = (rule.seedRatio ?? 2) * 100
    return "做种 \(numberText(hours)) 小时或分享率 \(numberText(ratio))% 后清理"
  }

  private func numberText(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
  }

  private func addGroup() {
    var groups = brushDraft.brushGroups
    let group = BrushGroup(id: UUID().uuidString.lowercased(), name: "新分组")
    groups.append(group)
    brushDraft.brushGroups = groups
    selectedGroupID = group.id
  }

  private func deleteGroups(at offsets: IndexSet) {
    var groups = brushDraft.brushGroups
    guard groups.count - offsets.count >= 1 else { return }
    groups.remove(atOffsets: offsets)
    brushDraft.brushGroups = groups
    if !groups.contains(where: { $0.id == selectedGroupID }) {
      selectedGroupID = groups.first?.id ?? ""
    }
  }

  private func syncBrushDraft(_ settings: BrushSettings) {
    brushDraft = settings
    let groups = settings.brushGroups
    if !groups.contains(where: { $0.id == selectedGroupID }) {
      selectedGroupID = groups.first?.id ?? ""
    }
  }
}

private struct BrushTaskAction {
  var task: BrushTask
  var action: String
  var deletesFiles: Bool
}

private struct MobileBrushSiteAccountRow: View {
  var account: BrushSiteAccount

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(account.siteName).font(.headline)
        Spacer()
        Text(account.status).font(.caption).foregroundStyle(account.error == nil ? Color.secondary : Color.orange)
      }
      HStack(spacing: 12) {
        Label(MobileFormat.bytes(account.uploadedBytes), systemImage: "arrow.up")
        Label(MobileFormat.bytes(account.downloadedBytes), systemImage: "arrow.down")
        if let ratio = account.ratio { Text("R \(ratio.formatted(.number.precision(.fractionLength(2))))") }
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      if let error = account.error, !error.isEmpty {
        Text(error).font(.caption).foregroundStyle(.orange)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct MobileBrushTaskRow: View {
  var task: BrushTask

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(task.title).font(.headline).lineLimit(2)
        Spacer(minLength: 8)
        MobileTag(text: task.status)
      }
      ProgressView(value: min(max(task.progress, 0), 1))
        .accessibilityLabel("任务进度")
        .accessibilityValue("\(Int(task.progress * 100))%")
      HStack(spacing: 10) {
        Label(MobileFormat.bytes(task.sizeBytes), systemImage: "externaldrive")
        Label(MobileFormat.bytes(task.downloaded), systemImage: "arrow.down.circle")
        Label(MobileFormat.bytes(task.uploaded), systemImage: "arrow.up.circle")
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      HStack(spacing: 10) {
        Text(task.siteName)
        if let group = task.groupName { Text(group) }
        Text("R \(task.ratio.formatted(.number.precision(.fractionLength(2))))")
      }
      .font(.caption)
      .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

private struct MobileBrushGroupSiteEditor: View {
  @Binding var group: BrushGroup

  var body: some View {
    Form {
      Section("分组") {
      MobileFormTextField(label: "分组名称", prompt: "例如：高优先级站点", text: $group.name)
        Toggle("启用分组", isOn: $group.enabled)
        Picker("组内站点顺序", selection: sequentialBinding) {
          Text("固定").tag(true)
          Text("随机").tag(false)
        }
        .pickerStyle(.segmented)
        if group.siteIds.isEmpty {
          Text("当前分组尚未分配站点。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          LabeledContent("已分配站点", value: "\(group.siteIds.count) 个")
          ForEach(group.siteIds, id: \.self) { siteID in
            Text(siteID)
          }
        }
      }
    }
    .mobileStatusNavigationTitle(group.name)
    .navigationBarTitleDisplayMode(.inline)
  }

  private var sequentialBinding: Binding<Bool> {
    Binding(get: { group.sequentialSites ?? false }, set: { group.sequentialSites = $0 })
  }
}

private struct MobileBrushRunHistoryView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      if store.brushRuns.isEmpty {
        ContentUnavailableView("暂无运行记录", systemImage: "clock.arrow.circlepath")
      } else {
        ForEach(store.brushRuns) { run in
          DisclosureGroup {
            LabeledContent("候选", value: "\(run.candidatesCount)")
            LabeledContent("匹配", value: "\(run.matchedCount)")
            LabeledContent("尝试提交", value: "\(run.attemptedCount)")
            LabeledContent("已添加", value: "\(run.addedCount)")
            LabeledContent("重复", value: "\(run.duplicateCount)")
            LabeledContent("失败", value: "\(run.errorCount + run.submissionFailedCount)")
            if let summary = run.summary, !summary.isEmpty { Text(summary).foregroundStyle(.secondary) }
            ForEach(run.details, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              HStack {
                Text(run.runType == "check" ? "任务检查" : "资源获取").font(.headline)
                Spacer()
                MobileTag(text: run.status)
              }
              Text("\(MobileFormat.date(run.startedAt)) · 添加 \(run.addedCount) · 跳过 \(run.skippedCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .mobileStatusNavigationTitle("运行记录")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("关闭", systemImage: "xmark") { dismiss() }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("刷新", systemImage: "arrow.clockwise") { Task { await store.refreshBrushRuns() } }
      }
    }
    .refreshable { await store.refreshBrushRuns() }
  }
}

private struct MobileOptionalDoubleField: View {
  var title: String
  @Binding var value: Double?
  var suffix: String
  @State private var text = ""
  @FocusState private var focused: Bool

  init(_ title: String, value: Binding<Double?>, suffix: String) {
    self.title = title
    self._value = value
    self.suffix = suffix
    self._text = State(initialValue: Self.display(value.wrappedValue))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent(title) {
        HStack(spacing: 6) {
          TextField("不限", text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .frame(maxWidth: 110)
          if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
        }
      }
      MobileFormValidationMessage(message: validationMessage)
    }
    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    .onChange(of: value) { _, newValue in if !focused { text = Self.display(newValue) } }
  }

  private func commit() {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { value = nil; text = ""; return }
    guard let parsed = Double(trimmed.replacingOccurrences(of: ",", with: ".")), parsed.isFinite, parsed >= 0 else {
      text = Self.display(value)
      return
    }
    value = parsed
    text = Self.display(parsed)
  }

  private var validationMessage: String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let parsed = Double(trimmed.replacingOccurrences(of: ",", with: ".")),
          parsed.isFinite,
          parsed >= 0 else {
      return "\(title)必须是大于或等于 0 的数字。"
    }
    return nil
  }

  private static func display(_ value: Double?) -> String {
    guard let value else { return "" }
    return value.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
  }
}

private struct MobileOptionalIntField: View {
  var title: String
  @Binding var value: Int?
  var suffix: String
  @State private var text = ""
  @FocusState private var focused: Bool

  init(_ title: String, value: Binding<Int?>, suffix: String) {
    self.title = title
    self._value = value
    self.suffix = suffix
    self._text = State(initialValue: value.wrappedValue.map(String.init) ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent(title) {
        HStack(spacing: 6) {
          TextField("不限", text: $text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .frame(maxWidth: 110)
          if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
        }
      }
      MobileFormValidationMessage(message: validationMessage)
    }
    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    .onChange(of: value) { _, newValue in if !focused { text = newValue.map(String.init) ?? "" } }
  }

  private func commit() {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { value = nil; text = ""; return }
    guard let parsed = Int(trimmed), parsed >= 0 else {
      text = value.map(String.init) ?? ""
      return
    }
    value = parsed
    text = String(parsed)
  }

  private var validationMessage: String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let parsed = Int(trimmed), parsed >= 0 else {
      return "\(title)必须是大于或等于 0 的整数。"
    }
    return nil
  }
}
