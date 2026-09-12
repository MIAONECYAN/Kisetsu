import SwiftUI

private enum BrushRuleCategory: String, CaseIterable, Identifiable {
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

struct BrushView: View {
  @EnvironmentObject private var store: AppStore
  @State private var tab = "overview"
  @State private var pendingTask: BrushTask?
  @State private var pendingAction = ""
  @State private var showingDestructiveConfirmation = false
  @State private var showingClearConfirmation = false
  @State private var ruleCategory: BrushRuleCategory = .general
  @State private var brushDraft = BrushSettings()
  @State private var savedBrushSettings = BrushSettings()
  @State private var selectedGroupID = ""
  @State private var pendingTab: String?
  @State private var showingUnsavedRulesAlert = false
  @State private var invalidNumericFields: Set<String> = []
  @State private var showingRunHistory = false

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Picker("刷流页面", selection: tabSelection) {
        Text("概览").tag("overview")
        Text("任务").tag("tasks")
        Text("规则").tag("rules")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 420)
      .padding(.top, 14)

      Group {
        switch tab {
        case "tasks": tasksView
        case "rules": rulesView
        default: overviewView
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .task {
      await store.loadBrush(silent: true)
      syncRuleDraft()
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(10))
        } catch {
          return
        }
        guard tab != "rules", !store.isLoading else { continue }
        await store.refreshBrushRuntime()
      }
    }
    .alert(actionTitle, isPresented: $showingDestructiveConfirmation) {
      Button(pendingAction == "delete_files" ? "删除任务和文件" : "删除任务", role: .destructive) {
        guard let pendingTask else { return }
        Task { await store.manageBrushTask(pendingTask, action: pendingAction) }
        self.pendingTask = nil
      }
      Button("取消", role: .cancel) { pendingTask = nil }
    } message: {
      Text(pendingAction == "delete_files" ? "Kisetsu 会先确认删除器与后端位于同一主机。macOS 下文件由后端直接永久删除，不进入废纸篓且无法恢复；其他环境由下载器原生删除。安全校验失败时会保留任务和文件。任务已不存在时只清理本地记录，不直接处理磁盘文件。" : "任务存在时从原下载器移除并保留文件；任务已不存在时只清理本地记录。")
    }
    .alert("清理已结束的刷流记录？", isPresented: $showingClearConfirmation) {
      Button("清理记录", role: .destructive) { Task { await store.clearBrushRecords() } }
      Button("取消", role: .cancel) {}
    } message: {
      Text("将清理已删除、已归档和异常记录及运行日志，不会删除活动任务或普通下载历史。")
    }
    .alert("规则尚未保存", isPresented: $showingUnsavedRulesAlert) {
      Button("保存并离开") { Task { await saveRulesAndLeave() } }
      Button("放弃修改", role: .destructive) { discardRulesAndLeave() }
      Button("继续编辑", role: .cancel) { pendingTab = nil }
    } message: {
      Text("离开规则页前，请保存或放弃本次修改。")
    }
    .sheet(isPresented: $showingRunHistory) {
      BrushRunHistoryView(runs: store.brushRuns) {
        await store.refreshBrushRuns()
      }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(store.brushStatus?.schedulerRunning == true ? Color.green : Color.secondary.opacity(0.45))
        .frame(width: 8, height: 8)
      Text(store.brushStatus?.message ?? "正在读取刷流状态")
        .font(.subheadline.weight(.medium))
      Spacer()
      Button {
        Task { await store.checkBrushNow() }
      } label: {
        Label("检查任务", systemImage: "checkmark.arrow.trianglehead.counterclockwise")
      }
      .disabled(store.isLoading)
      Button {
        Task { await store.runBrushNow() }
      } label: {
        Label("立即刷流", systemImage: "bolt.fill")
      }
      .disabled(store.isLoading)
      Button {
        Task {
          if store.brushStatus?.schedulerRunning == true {
            await store.stopBrush()
          } else {
            await store.startBrush()
          }
        }
      } label: {
        Label(
          store.brushStatus?.schedulerRunning == true ? "停止" : "启动",
          systemImage: store.brushStatus?.schedulerRunning == true ? "stop.fill" : "play.fill"
        )
      }
      .disabled(store.isLoading)
      Button {
        Task { await store.loadBrush() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .help("刷新刷流状态")
      .disabled(store.isLoading)
      Menu {
        Button(role: .destructive) { showingClearConfirmation = true } label: {
          Label("清理已结束记录", systemImage: "eraser")
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .appToolbarSurface()
  }

  private var overviewView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: KisetsuStyle.sectionSpacing) {
        if let status = store.brushStatus {
          let transfer = BrushDownloaderTransferPresentation(transfer: status.downloaderTransfer)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            metric("活动任务", "\(status.stats.activeTasks)", "arrow.down.circle", .blue)
            metric("正在做种", "\(status.stats.seedingTasks)", "arrow.up.circle", .green)
            metric("刷流占用", ByteText.size(status.stats.occupiedBytes), "internaldrive", .orange)
            metric("总下载量", transfer.downloadedText, "arrow.down.to.line", .blue, help: transfer.sourceDescription)
            metric("总上传量", transfer.uploadedText, "arrow.up.to.line", .green, help: transfer.sourceDescription)
            metric("整体分享率", transfer.ratioText, "chart.line.uptrend.xyaxis", .purple, help: transfer.sourceDescription)
          }
          if let warning = transfer.warningText {
            Label(warning, systemImage: "exclamationmark.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.leading, 2)
              .help(transfer.errorHelp)
          }

          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("运行状态")
                .font(.headline)
              Spacer()
              Button {
                showingRunHistory = true
                Task { await store.refreshBrushRuns() }
              } label: {
                Label("运行记录", systemImage: "clock.arrow.circlepath")
              }
              .buttonStyle(.borderless)
            }
            statusLine("下次获取资源", status.nextBrushAt)
            statusLine("下次检查任务", status.nextCheckAt)
            statusLine("最近获取资源", status.lastBrushAt)
            statusLine("最近检查任务", status.lastCheckAt)
            if let error = status.lastError, !error.isEmpty {
              Label(error, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
            }
          }
          .padding(16)
          .animeCard()
        }

        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text("站点账户")
              .font(.headline)
            Spacer()
            Button {
              Task { await store.refreshBrushSiteAccounts() }
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新站点账户")
          }
          .padding(.bottom, 10)

          if store.brushSiteAccounts.isEmpty {
            Text("启用刷流站点后显示账户流量")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          } else {
            ForEach(Array(store.brushSiteAccounts.enumerated()), id: \.element.id) { index, account in
              BrushSiteAccountRow(account: account) {
                Task { await store.refreshBrushSiteAccounts() }
              }
              if index + 1 < store.brushSiteAccounts.count { Divider() }
            }
          }
        }
        .padding(16)
        .animeCard()

      }
      .appPageContent()
    }
  }

  private var tasksView: some View {
    VStack(spacing: 0) {
      HStack {
        Toggle("显示已结束", isOn: $store.showArchivedBrushTasks)
          .toggleStyle(.checkbox)
          .onChange(of: store.showArchivedBrushTasks) {
            Task { await store.loadBrush(silent: true) }
          }
        Spacer()
        Text("\(store.brushTasks.count) 条刷流任务")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, KisetsuStyle.pagePadding)
      .padding(.vertical, 10)

      Group {
        if store.brushTasks.isEmpty {
          ContentUnavailableView("暂无刷流任务", systemImage: "arrow.up.arrow.down.circle", description: Text("启用刷流后，符合规则的任务会显示在这里。"))
        } else {
          List(store.brushTasks) { task in
            BrushTaskRow(
              task: task,
              canDeleteFiles: task.downloaderType != "transmission" || store.brushStatus?.transmissionDeleteCapability?.available == true,
              deleteFilesUnavailableReason: store.brushStatus?.transmissionDeleteCapability?.reason
            ) { action in
              if action == "delete" || action == "delete_files" {
                pendingTask = task
                pendingAction = action
                showingDestructiveConfirmation = true
              } else {
                Task { await store.manageBrushTask(task, action: action) }
              }
            }
          }
          .listStyle(.inset)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }


  private var rulesView: some View {
    HStack(alignment: .top, spacing: 20) {
      BrushRuleCategoryPicker(selection: $ruleCategory)
        .frame(width: 190)

      VStack(spacing: 0) {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(ruleCategory.title)
              .font(.headline)
            if rulesAreDirty {
              Text("有未保存的修改")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button {
            Task { await reloadRuleDraft() }
          } label: {
            Label("重新载入", systemImage: "arrow.clockwise")
          }
          .disabled(store.isLoading)
          Button {
            Task { await saveRuleDraft() }
          } label: {
            Label("保存规则", systemImage: "square.and.arrow.down")
          }
          .buttonStyle(.borderedProminent)
          .disabled(store.isLoading || !rulesAreDirty || !ruleValidationMessages.isEmpty || !invalidNumericFields.isEmpty)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 10)

        Form {
          if !ruleValidationMessages.isEmpty || !invalidNumericFields.isEmpty {
            Section {
              ruleValidationSummary
            }
          }
          selectedRuleForm
        }
        .formStyle(.grouped)
        .frame(maxWidth: 860, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .padding(.horizontal, KisetsuStyle.pagePadding)
    .padding(.top, 14)
    .frame(maxWidth: KisetsuStyle.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var selectedRuleForm: some View {
    switch ruleCategory {
    case .general:
      Section("通知") {
        Toggle("发送 Bark 通知", isOn: $brushDraft.notificationsEnabled)
      }
      Section("目录") {
        LabeledDirectoryPathField(
          label: "刷流专用目录",
          placeholder: "输入路径或选择文件夹",
          path: $brushDraft.savePath
        )
      }
      Section("调度") {
        RequiredIntegerField("获取间隔", value: $brushDraft.brushIntervalMinutes, suffix: "分钟", minimum: 1, maximum: 1440, showsStepper: true, validity: numericValidity("brushIntervalMinutes"))
      }
      Section("运行时段") {
        Toggle("限制运行时段", isOn: activeTimeEnabled)
        if activeTimeEnabled.wrappedValue {
          TimePickerRow("开始时间", value: activeTimeBinding($brushDraft.activeTimeStart, fallbackHour: 0))
          TimePickerRow("结束时间", value: activeTimeBinding($brushDraft.activeTimeEnd, fallbackHour: 7))
          Text("结束时间早于开始时间时，将运行至次日。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          LabeledContent("当前时段", value: "全天运行")
        }
      }

    case .cleanup:
      groupSelectionSection
      if let group = selectedGroup {
        Section("当前规则") {
          LabeledContent("清理条件", value: cleanupSummary(group.rule.seedTimeHours, group.rule.seedRatio))
          Text("下载完成后，任一条件达成即可清理。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section("达标条件") {
          RequiredNumberField(
            "做种时间",
            value: requiredNumber(selectedGroupRuleBinding.seedTimeHours, fallback: 72),
            suffix: "小时",
            validity: numericValidity("group.\(group.id).seedTimeHours")
          )
          RequiredNumberField(
            "分享率",
            value: ratioPercent(selectedGroupRuleBinding.seedRatio, fallback: 2),
            suffix: "%",
            validity: numericValidity("group.\(group.id).seedRatio")
          )
        }
      } else {
        missingGroupSection
      }
      Section("清理行为") {
        Toggle("清理时同时删除刷流文件", isOn: $brushDraft.deleteFilesOnCleanup)
        if brushDraft.deleteFilesOnCleanup {
          Text("达标清理前会确认下载器与后端的主机和路径关系；macOS 由后端永久删除，其他环境使用下载器原生删除。校验失败时保留任务和文件。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Toggle("自动隐藏已结束记录", isOn: archiveEnabled)
        if archiveEnabled.wrappedValue {
          RequiredIntegerField(
            "隐藏等待时间",
            value: requiredInteger($brushDraft.archiveAfterDays, fallback: 30),
            suffix: "天",
            minimum: 1,
            validity: numericValidity("archiveAfterDays")
          )
        }
        Text("只隐藏已删除、异常或已丢失的历史记录，不会删除任务或文件。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

    case .sites:
      Section {
        ForEach(brushDraft.brushGroups) { group in
          VStack(alignment: .leading, spacing: 10) {
            LabeledContent("分组名称") {
              HStack(spacing: 10) {
                TextField("", text: groupBinding(group.id).name, prompt: Text("输入名称"))
                  .textFieldStyle(.roundedBorder)
                  .frame(maxWidth: 280)
                  .accessibilityLabel("分组名称")
                Text("\(group.siteIds.count) 个站点")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .monospacedDigit()
                Button {
                  removeGroup(group.id)
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除分组")
                .accessibilityLabel("删除 \(group.name)")
                .disabled(brushDraft.brushGroups.count == 1)
              }
            }
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 24) {
                Toggle("参与刷流", isOn: groupBinding(group.id).enabled)
                  .toggleStyle(.switch)
                  .fixedSize()
                Spacer(minLength: 12)
                groupSiteOrderPicker(group.id)
              }
              VStack(alignment: .leading, spacing: 10) {
                Toggle("参与刷流", isOn: groupBinding(group.id).enabled)
                  .toggleStyle(.switch)
                groupSiteOrderPicker(group.id)
              }
            }
            .font(.subheadline)
          }
        }
      } header: {
        HStack {
          Text("分组")
          Spacer()
          Button(action: addGroup) {
            Label("新建分组", systemImage: "plus")
          }
          .buttonStyle(.borderless)
        }
      }
      Section("站点分配") {
        ForEach(brushSiteIDs, id: \.self) { siteID in
          Picker(store.siteLabel(for: siteID), selection: siteGroupBinding(siteID)) {
            Text("不参与刷流").tag("")
            ForEach(brushDraft.brushGroups) { group in
              Text(group.name).tag(group.id)
            }
          }
          .pickerStyle(.menu)
        }
        Text("一个站点只能属于一个分组；选择其他分组会直接移动该站点，保存前可以重新载入撤销。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case .filters:
      groupSelectionSection
      if let group = selectedGroup {
        Section("优惠") {
          LabeledContent("优惠要求") {
            BrushPromotionSelectionMenu(rule: selectedGroupRuleBinding)
          }
        }
        Section("体积") {
          OptionalNumberField("最小体积", value: selectedGroupRuleBinding.sizeMinGb, suffix: "GB", validity: numericValidity("group.\(group.id).sizeMinGb"))
          OptionalNumberField("最大体积", value: selectedGroupRuleBinding.sizeMaxGb, suffix: "GB", validity: numericValidity("group.\(group.id).sizeMaxGb"))
          if let message = groupSizeValidationMessage(group) { validationMessage(message) }
        }
        Section("活跃度") {
          OptionalIntegerField("最少做种数", value: selectedGroupRuleBinding.seedersMin, validity: numericValidity("group.\(group.id).seedersMin"))
          OptionalIntegerField("最多做种数", value: selectedGroupRuleBinding.seedersMax, validity: numericValidity("group.\(group.id).seedersMax"))
          if let message = groupSeedersValidationMessage(group) { validationMessage(message) }
        }
        Section("发布时间") {
          OptionalIntegerField(
            "发布至少经过",
            value: selectedGroupRuleBinding.publishAgeMinMinutes,
            suffix: "分钟",
            validity: numericValidity("group.\(group.id).publishAgeMinMinutes")
          )
          OptionalIntegerField(
            "仅获取最近",
            value: selectedGroupRuleBinding.publishAgeMaxMinutes,
            suffix: "分钟",
            defaultValue: 120,
            validity: numericValidity("group.\(group.id).publishAgeMaxMinutes")
          )
          if let message = groupPublishAgeValidationMessage(group) { validationMessage(message) }
          Text("例如设为 120 分钟时，只获取发布时间在最近 2 小时内的资源。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section("关键词") {
          LabeledContent("包含正则") {
            TextField("", text: optionalText(selectedGroupRuleBinding.includePattern), prompt: Text("输入包含规则"))
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 420)
          }
          LabeledContent("排除正则") {
            TextField("", text: optionalText(selectedGroupRuleBinding.excludePattern), prompt: Text("输入排除规则"))
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 420)
          }
          Toggle("排除现有订阅相关资源", isOn: selectedGroupBinding.excludeSubscriptions)
        }
      } else {
        missingGroupSection
      }

    case .advanced:
      Section("共享容量") {
        OptionalNumberField("最大刷流占用", value: $brushDraft.maxStorageGb, suffix: "GB", minimum: 0.1, validity: numericValidity("maxStorageGb"))
        Text("所有分组共享同一个最大刷流占用，避免分别计算后超过实际磁盘容量。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      groupSelectionSection
      if let group = selectedGroup {
        Section("分组容量") {
          OptionalIntegerField("最大任务数", value: selectedGroupBinding.maxTasks, minimum: 1, validity: numericValidity("group.\(group.id).maxTasks"))
          OptionalIntegerField("最大同时下载数", value: selectedGroupBinding.maxDownloading, minimum: 1, validity: numericValidity("group.\(group.id).maxDownloading"))
          Text("最大任务数包含该分组中下载、暂停、校验和做种的任务；留空表示不限制。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section("单轮任务") {
          RequiredIntegerField("最多新增", value: selectedGroupBinding.maxAdditionsPerRun, suffix: "条", minimum: 1, maximum: 100, showsStepper: true, validity: numericValidity("group.\(group.id).maxAdditionsPerRun"))
          RequiredIntegerField("每站读取", value: selectedGroupBinding.candidatesPerSite, suffix: "条", minimum: 1, maximum: 100, showsStepper: true, validity: numericValidity("group.\(group.id).candidatesPerSite"))
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

  private func metric(_ title: String, _ value: String, _ symbol: String, _ color: Color, help: String? = nil) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.title3)
        .foregroundStyle(color)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text(value)
          .font(.title3.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.75)
        Text(title).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(14)
    .animeCard()
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title)，\(value)")
    .help(help ?? "\(title)：\(value)")
  }

  private func statusLine(_ title: String, _ value: String?) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value.map(AppRelativeTime.concise) ?? "尚无记录")
    }
    .font(.subheadline)
  }

  private var brushSiteIDs: [String] { ["mteam", "hddolby", "soulvoice", "opencd"] }

  private var selectedGroup: BrushGroup? {
    brushDraft.brushGroups.first { $0.id == selectedGroupID }
  }

  private var selectedGroupBinding: Binding<BrushGroup> {
    groupBinding(selectedGroupID)
  }

  private var selectedGroupRuleBinding: Binding<BrushRule> {
    selectedGroupBinding.rule
  }

  private func groupBinding(_ groupID: String) -> Binding<BrushGroup> {
    Binding {
      brushDraft.brushGroups.first { $0.id == groupID }
        ?? brushDraft.brushGroups.first
        ?? BrushGroup(id: "default", name: "默认分组")
    } set: { newValue in
      var groups = brushDraft.brushGroups
      guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
      groups[index] = newValue
      brushDraft.brushGroups = groups
    }
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

  private func groupSequentialSitesBinding(_ groupID: String) -> Binding<Bool> {
    Binding {
      groupBinding(groupID).wrappedValue.sequentialSites ?? brushDraft.sequentialSites
    } set: { sequential in
      var group = groupBinding(groupID).wrappedValue
      group.sequentialSites = sequential
      groupBinding(groupID).wrappedValue = group
    }
  }

  private func groupSiteOrderPicker(_ groupID: String) -> some View {
    LabeledContent("组内站点顺序") {
      Picker("组内站点顺序", selection: groupSequentialSitesBinding(groupID)) {
        Text("固定").tag(true)
        Text("随机").tag(false)
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(width: 144)
      .help("固定会按照站点分配列表顺序获取；随机会在每轮打乱该组内站点顺序。")
      .accessibilityValue(groupSequentialSitesBinding(groupID).wrappedValue ? "固定顺序" : "随机顺序")
    }
  }

  private func addGroup() {
    var groups = brushDraft.brushGroups
    let usedNames = Set(groups.map { $0.name.lowercased() })
    var name = "新分组"
    var suffix = 2
    while usedNames.contains(name.lowercased()) {
      name = "新分组 \(suffix)"
      suffix += 1
    }
    let group = BrushGroup(id: UUID().uuidString.lowercased(), name: name)
    groups.append(group)
    brushDraft.brushGroups = groups
    selectedGroupID = group.id
  }

  private func removeGroup(_ groupID: String) {
    guard brushDraft.brushGroups.count > 1 else { return }
    var groups = brushDraft.brushGroups
    groups.removeAll { $0.id == groupID }
    brushDraft.brushGroups = groups
    clearNumericValidity(prefix: "group.\(groupID).")
    if selectedGroupID == groupID { selectedGroupID = groups.first?.id ?? "" }
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

  private func optionalText(_ binding: Binding<String?>) -> Binding<String> {
    Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
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
      clockDate(binding.wrappedValue, fallbackHour: fallbackHour)
    } set: { newValue in
      binding.wrappedValue = clockText(newValue)
    }
  }

  private func clockDate(_ value: String?, fallbackHour: Int) -> Date {
    let pieces = value?.split(separator: ":").compactMap { Int($0) } ?? []
    let hour = pieces.count == 2 ? pieces[0] : fallbackHour
    let minute = pieces.count == 2 ? pieces[1] : 0
    return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
  }

  private func clockText(_ value: Date) -> String {
    let components = Calendar.current.dateComponents([.hour, .minute], from: value)
    return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
  }

  private var archiveEnabled: Binding<Bool> {
    Binding {
      brushDraft.archiveAfterDays != nil
    } set: { enabled in
      brushDraft.archiveAfterDays = enabled ? (brushDraft.archiveAfterDays ?? 30) : nil
      if !enabled { invalidNumericFields.remove("archiveAfterDays") }
    }
  }

  private func requiredNumber(_ binding: Binding<Double?>, fallback: Double) -> Binding<Double> {
    Binding(get: { binding.wrappedValue ?? fallback }, set: { binding.wrappedValue = max(0, $0) })
  }

  private func requiredInteger(_ binding: Binding<Int?>, fallback: Int) -> Binding<Int> {
    Binding(get: { binding.wrappedValue ?? fallback }, set: { binding.wrappedValue = $0 })
  }

  private func ratioPercent(_ binding: Binding<Double?>, fallback: Double) -> Binding<Double> {
    Binding(get: { (binding.wrappedValue ?? fallback) * 100 }, set: { binding.wrappedValue = max(0, $0) / 100 })
  }

  private func cleanupSummary(_ hours: Double?, _ ratio: Double?) -> String {
    let hourText = numberText(hours ?? 72)
    let ratioText = numberText((ratio ?? 2) * 100)
    return "做种 \(hourText) 小时或分享率 \(ratioText)% 后清理"
  }

  private func numberText(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
  }

  private func groupSizeValidationMessage(_ group: BrushGroup) -> String? {
    rangeValidationMessage(
      minimum: group.rule.sizeMinGb,
      maximum: group.rule.sizeMaxGb,
      message: "最小体积不能大于最大体积。"
    )
  }

  private func groupSeedersValidationMessage(_ group: BrushGroup) -> String? {
    rangeValidationMessage(
      minimum: group.rule.seedersMin,
      maximum: group.rule.seedersMax,
      message: "最少做种不能大于最多做种。"
    )
  }

  private func groupPublishAgeValidationMessage(_ group: BrushGroup) -> String? {
    rangeValidationMessage(
      minimum: group.rule.publishAgeMinMinutes,
      maximum: group.rule.publishAgeMaxMinutes,
      message: "“发布至少经过”不能大于“仅获取最近”。"
    )
  }

  private func rangeValidationMessage<T: Comparable>(minimum: T?, maximum: T?, message: String) -> String? {
    guard let minimum, let maximum, minimum > maximum else { return nil }
    return message
  }

  private var ruleValidationMessages: [String] {
    var messages: [String] = []
    let groups = brushDraft.brushGroups
    let names = groups.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    if names.contains(where: \.isEmpty) { messages.append("分组名称不能为空。") }
    if names.contains(where: { $0.count > 40 }) { messages.append("分组名称不能超过 40 个字符。") }
    if Set(names.map { $0.lowercased() }).count != names.count { messages.append("分组名称不能重复。") }
    if !groups.contains(where: { $0.enabled && !$0.siteIds.isEmpty }) {
      messages.append("请至少为一个已启用分组分配站点。")
    }
    for group in groups {
      if let message = groupSizeValidationMessage(group) { messages.append("\(group.name)：\(message)") }
      if let message = groupSeedersValidationMessage(group) { messages.append("\(group.name)：\(message)") }
      if let message = groupPublishAgeValidationMessage(group) { messages.append("\(group.name)：\(message)") }
    }
    return messages
  }

  @ViewBuilder
  private var ruleValidationSummary: some View {
    if !invalidNumericFields.isEmpty {
      validationMessage("请修正格式不正确或超出范围的数字。")
    }
    ForEach(Array(Set(ruleValidationMessages)).sorted(), id: \.self) { message in
      validationMessage(message)
    }
  }

  private func validationMessage(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.circle")
      .font(.caption)
      .foregroundStyle(.red)
  }

  private func numericValidity(_ key: String) -> (Bool) -> Void {
    { isValid in
      if isValid {
        invalidNumericFields.remove(key)
      } else {
        invalidNumericFields.insert(key)
      }
    }
  }

  private func clearNumericValidity(prefix: String) {
    invalidNumericFields = invalidNumericFields.filter { !$0.hasPrefix(prefix) }
  }

  private var tabSelection: Binding<String> {
    Binding {
      tab
    } set: { newTab in
      guard newTab != tab else { return }
      if tab == "rules", newTab != "rules", rulesAreDirty {
        pendingTab = newTab
        showingUnsavedRulesAlert = true
      } else {
        tab = newTab
        if newTab == "rules", !rulesAreDirty { syncRuleDraft() }
      }
    }
  }

  private var rulesAreDirty: Bool {
    !brushDraft.hasSameRuleConfiguration(as: savedBrushSettings)
  }

  private func syncRuleDraft() {
    var settings = store.brushSettings
    settings.materializeBrushGroups()
    brushDraft = settings
    savedBrushSettings = settings
    ensureSelectedGroup()
    invalidNumericFields.removeAll()
  }

  private func ensureSelectedGroup() {
    guard !brushDraft.brushGroups.contains(where: { $0.id == selectedGroupID }) else { return }
    selectedGroupID = brushDraft.brushGroups.first?.id ?? ""
  }

  private func reloadRuleDraft() async {
    await store.loadBrush()
    syncRuleDraft()
  }

  private func saveRuleDraft() async {
    guard invalidNumericFields.isEmpty, ruleValidationMessages.isEmpty else { return }
    let payload = brushDraft.preservingRuntimeEnabled(store.brushSettings.enabled)
    if await store.saveBrushSettings(payload) {
      syncRuleDraft()
    }
  }

  private func saveRulesAndLeave() async {
    await saveRuleDraft()
    guard !rulesAreDirty, let destination = pendingTab else { return }
    pendingTab = nil
    tab = destination
  }

  private func discardRulesAndLeave() {
    brushDraft = savedBrushSettings
    ensureSelectedGroup()
    guard let destination = pendingTab else { return }
    pendingTab = nil
    tab = destination
  }

  private var actionTitle: String {
    pendingAction == "delete_files" ? "删除刷流任务和文件？" : "删除刷流任务？"
  }
}

private struct BrushRuleCategoryPicker: View {
  @Binding var selection: BrushRuleCategory

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(BrushRuleCategory.allCases) { category in
        SettingsNavigationRow(
          title: category.title,
          symbol: category.symbol,
          isSelected: selection == category
        ) {
          selection = category
        }
      }
    }
    .padding(.vertical, 2)
    .onMoveCommand { direction in
      guard let index = BrushRuleCategory.allCases.firstIndex(of: selection) else { return }
      switch direction {
      case .up where index > 0:
        selection = BrushRuleCategory.allCases[index - 1]
      case .down where index + 1 < BrushRuleCategory.allCases.count:
        selection = BrushRuleCategory.allCases[index + 1]
      default:
        break
      }
    }
  }
}

private struct BrushSiteAccountRow: View {
  var account: BrushSiteAccount
  var retry: () -> Void

  var body: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 2) {
        Text(account.siteName)
          .font(.subheadline)
        Text(AppRelativeTime.concise(account.fetchedAt))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .frame(width: 120, alignment: .leading)

      if account.status == "success" {
        accountMetric("上传", account.uploadedBytes.map(ByteText.size) ?? "—", .green)
        accountMetric("下载", account.downloadedBytes.map(ByteText.size) ?? "—", .blue)
        accountMetric("分享率", account.ratio.map { String(format: "%.2f", $0) } ?? "—", .primary)
      } else {
        Text(account.error ?? "暂时无法获取账户信息")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Spacer()
        Button(action: retry) {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("重试")
      }
    }
    .padding(.vertical, 9)
  }

  private func accountMetric(_ label: String, _ value: String, _ color: Color) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(value)
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(color)
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

private struct BrushRunHistoryView: View {
  @Environment(\.dismiss) private var dismiss
  var runs: [BrushRun]
  var refresh: () async -> Void
  @State private var refreshing = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("运行记录")
            .font(.title3.weight(.semibold))
          Text("查看资源获取、任务检查与新增刷流任务")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          Task {
            refreshing = true
            await refresh()
            refreshing = false
          }
        } label: {
          if refreshing {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .help("刷新运行记录")
        .disabled(refreshing)
        Button("完成") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(20)

      Divider()

      if runs.isEmpty {
        ContentUnavailableView("暂无运行记录", systemImage: "clock.arrow.circlepath")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(runs) { run in
          DisclosureGroup {
            BrushRunHistoryDetails(run: run)
              .padding(.vertical, 8)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: run.runType == "brush" ? "arrow.down.circle" : "checkmark.circle")
                .foregroundStyle(run.status == "error" ? .red : .secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(run.summary ?? (run.runType == "brush" ? "获取刷流资源" : "检查刷流任务"))
                Text(AppRelativeTime.concise(run.startedAt))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text(runStatus(run.status))
                .font(.caption)
                .foregroundStyle(run.status == "error" ? .red : .secondary)
            }
          }
        }
      }
    }
    .frame(minWidth: 680, minHeight: 560)
  }

  private func runStatus(_ status: String) -> String {
    switch status {
    case "success": "完成"
    case "partial": "部分完成"
    case "error": "失败"
    case "running": "运行中"
    default: "已跳过"
    }
  }
}

private struct BrushRunHistoryDetails: View {
  var run: BrushRun

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
      detailRow("触发方式", run.trigger == "manual" ? "立即执行" : run.trigger == "scheduler" ? "定时" : "未记录")
      detailRow("处理站点", siteNames)
      detailRow("运行汇总", "读取 \(run.candidatesCount) · 符合 \(run.matchedCount) · 新增 \(run.addedCount) · 跳过 \(run.skippedCount) · 失败 \(run.errorCount)")
      if let summary = run.summary, !summary.isEmpty {
        detailRow("运行结果", summary)
      }
      if !diagnosticsWithRejections.isEmpty {
        Divider().gridCellColumns(2)
        Text("规则排除").font(.subheadline.weight(.semibold)).gridCellColumns(2)
        ForEach(diagnosticsWithRejections) { diagnostic in
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
              Text(diagnosticName(diagnostic))
                .font(.subheadline.weight(.medium))
              Spacer(minLength: 12)
              Text("排除 \(diagnostic.rejectionReasons.values.reduce(0, +)) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            ForEach(diagnostic.rejectionReasons.sorted(by: rejectionReasonOrder), id: \.key) { reason, count in
              ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                  Text("\(reason) \(count) 条")
                    .monospacedDigit()
                  Spacer(minLength: 12)
                  if let location = BrushRuleSettingLocation.path(forRejectionReason: reason) {
                    Label(location, systemImage: "slider.horizontal.3")
                      .foregroundStyle(.secondary)
                  }
                }
                VStack(alignment: .leading, spacing: 3) {
                  Text("\(reason) \(count) 条")
                    .monospacedDigit()
                  if let location = BrushRuleSettingLocation.path(forRejectionReason: reason) {
                    Label(location, systemImage: "slider.horizontal.3")
                      .foregroundStyle(.secondary)
                  }
                }
              }
              .font(.caption)
              .accessibilityElement(children: .combine)
            }
          }
          .gridCellColumns(2)
        }
      }
      if !run.addedTasks.isEmpty {
        Divider().gridCellColumns(2)
        Text("新增任务").font(.subheadline.weight(.semibold)).gridCellColumns(2)
        ForEach(run.addedTasks) { task in
          VStack(alignment: .leading, spacing: 3) {
            Text(task.title).lineLimit(2).help(task.title)
            Text("\(task.groupName.map { "\($0) · " } ?? "")\(task.siteName) · \(task.sizeBytes.map { ByteText.size($0) } ?? "体积未知") · \(task.promotionLabel ?? "无优惠") · \(task.downloaderType == "transmission" ? "Transmission" : "qBittorrent") · \(taskStatus(task.status))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .gridCellColumns(2)
          .accessibilityElement(children: .combine)
        }
      } else if run.addedCount > 0 {
        Text("本次运行未记录任务详情")
          .font(.caption)
          .foregroundStyle(.secondary)
          .gridCellColumns(2)
      }
      ForEach(Array(supplementaryDetails.enumerated()), id: \.offset) { _, detail in
        Text(detail).font(.caption).foregroundStyle(.secondary).gridCellColumns(2)
      }
    }
  }

  private func detailRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value)
    }
  }

  private var siteNames: String {
    let value = run.siteDiagnostics.map { diagnostic in
      diagnostic.groupName.map { "\($0) · \(diagnostic.siteName)" } ?? diagnostic.siteName
    }.joined(separator: "、")
    return value.isEmpty ? "未记录" : value
  }

  private var diagnosticsWithRejections: [BrushSiteRunDiagnostic] {
    run.siteDiagnostics.filter { !$0.rejectionReasons.isEmpty }
  }

  private var supplementaryDetails: [String] {
    guard !diagnosticsWithRejections.isEmpty else { return run.details }
    return run.details.filter { !$0.hasPrefix("跳过原因：") }
  }

  private func diagnosticName(_ diagnostic: BrushSiteRunDiagnostic) -> String {
    diagnostic.groupName.map { "\($0) · \(diagnostic.siteName)" } ?? diagnostic.siteName
  }

  private func rejectionReasonOrder(
    _ left: Dictionary<String, Int>.Element,
    _ right: Dictionary<String, Int>.Element
  ) -> Bool {
    if left.value != right.value { return left.value > right.value }
    return left.key < right.key
  }

  private func taskStatus(_ status: String) -> String {
    switch status {
    case "submitting": "提交中"
    case "downloading": "下载中"
    case "seeding": "做种中"
    case "paused": "已暂停"
    case "deleted": "已删除"
    case "archived": "已归档"
    case "error": "异常"
    case "missing": "任务不存在"
    default: status
    }
  }
}

private struct BrushPromotionSelectionMenu: View {
  @Binding var rule: BrushRule

  var body: some View {
    Menu {
      Toggle("FREE", isOn: selectionBinding("free"))
      Toggle("双倍上传 FREE", isOn: selectionBinding("2xfree"))
      Divider()
      Button {
        rule.clearPromotionSelection()
      } label: {
        if rule.effectivePromotionModes.isEmpty {
          Label("不限制优惠", systemImage: "checkmark")
        } else {
          Text("不限制优惠")
        }
      }
    } label: {
      Label(rule.promotionSelectionSummary, systemImage: "tag")
        .lineLimit(1)
        .frame(width: 220, alignment: .leading)
    }
    .help("可同时选择 FREE 和双倍上传 FREE")
    .accessibilityLabel("优惠要求")
    .accessibilityValue(rule.promotionSelectionSummary)
  }

  private func selectionBinding(_ mode: String) -> Binding<Bool> {
    Binding {
      rule.effectivePromotionModes.contains(mode)
    } set: { enabled in
      rule.setPromotionSelection(mode, enabled: enabled)
    }
  }
}

private struct BrushTaskRow: View {
  var task: BrushTask
  var canDeleteFiles: Bool
  var deleteFilesUnavailableReason: String?
  var manage: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .firstTextBaseline) {
        Text(task.title)
          .font(.headline)
          .lineLimit(2)
        Spacer()
        Text(statusText)
          .font(.caption.weight(.medium))
          .foregroundStyle(statusColor)
      }
      if let subtitle = task.subtitle, !subtitle.isEmpty, subtitle != task.title {
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      ProgressView(value: min(max(task.progress, 0), 1))
      transferMetrics
      HStack(spacing: 14) {
        Text(task.groupName.map { "\($0) · \(task.siteName)" } ?? task.siteName)
        Text(task.downloaderType == "transmission" ? "Transmission" : "qBittorrent")
        Text("\(Int(task.progress * 100))%")
        Label(ByteText.speed(task.downloadSpeed), systemImage: "arrow.down")
        Label(ByteText.speed(task.uploadSpeed), systemImage: "arrow.up")
        Text("分享率 \(String(format: "%.2f", task.ratio))")
        Text("做种 \(duration(task.seedingTime))")
        Spacer()
        Menu {
          Button("暂停") { manage("pause") }
          Button("恢复") { manage("resume") }
          Divider()
          Button("删除任务", role: .destructive) { manage("delete") }
          Button("删除任务和文件", role: .destructive) { manage("delete_files") }
            .disabled(!canDeleteFiles)
            .help(canDeleteFiles ? "永久删除任务和文件" : (deleteFilesUnavailableReason ?? "正在确认永久删除能力"))
          Button("归档记录") { manage("archive") }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if let reason = task.cleanupReason, !reason.isEmpty {
        Text("清理原因：\(reason)").font(.caption).foregroundStyle(.secondary)
      } else if let error = task.errorMessage, !error.isEmpty {
        Text(error).font(.caption).foregroundStyle(.orange)
      } else if let cleanupSummary {
        Label(cleanupSummary, systemImage: "clock.arrow.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 6)
  }

  private var transferMetrics: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 18) {
        transferMetric("体积", value: task.sizeBytes.map(ByteText.size) ?? "—", systemImage: "externaldrive")
        transferMetric("已下载", value: downloadedText, systemImage: "arrow.down.circle")
        transferMetric("已上传", value: uploadedText, systemImage: "arrow.up.circle")
      }
      .fixedSize(horizontal: true, vertical: false)

      VStack(alignment: .leading, spacing: 5) {
        transferMetric("体积", value: task.sizeBytes.map(ByteText.size) ?? "—", systemImage: "externaldrive")
        transferMetric("已下载", value: downloadedText, systemImage: "arrow.down.circle")
        transferMetric("已上传", value: uploadedText, systemImage: "arrow.up.circle")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .monospacedDigit()
  }

  private func transferMetric(_ title: String, value: String, systemImage: String) -> some View {
    Label("\(title) \(value)", systemImage: systemImage)
      .help("\(title)：\(value)")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(title)，\(value)")
  }

  private var downloadedText: String {
    task.lastCheckedAt == nil ? "—" : ByteText.size(task.downloaded)
  }

  private var uploadedText: String {
    task.lastCheckedAt == nil ? "—" : ByteText.size(task.uploaded)
  }

  private var statusText: String {
    switch task.status {
    case "submitting": "正在提交"
    case "downloading": "下载中"
    case "seeding": "做种中"
    case "paused": "已暂停"
    case "missing": "任务不存在"
    case "deleted": "已清理"
    case "archived": "已归档"
    default: "异常"
    }
  }

  private var statusColor: Color {
    switch task.status {
    case "seeding": .green
    case "downloading": .blue
    case "error", "missing": .orange
    default: .secondary
    }
  }

  private var cleanupSummary: String? {
    guard !["deleted", "archived", "missing", "error"].contains(task.status) else { return nil }
    let rule = task.ruleSnapshot.rule
    var conditions: [String] = []
    if let hours = rule?.seedTimeHours { conditions.append("做种 \(number(hours)) 小时") }
    if let ratio = rule?.seedRatio { conditions.append("分享率 \(number(ratio * 100))%") }
    return conditions.isEmpty ? nil : conditions.joined(separator: " 或 ") + " 后清理"
  }

  private func number(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
  }

  private func duration(_ seconds: Int) -> String {
    if seconds >= 86400 { return "\(seconds / 86400) 天" }
    if seconds >= 3600 { return "\(seconds / 3600) 小时" }
    return "\(max(0, seconds / 60)) 分钟"
  }
}

private struct TimePickerRow: View {
  var title: String
  @Binding var value: Date

  init(_ title: String, value: Binding<Date>) {
    self.title = title
    self._value = value
  }

  var body: some View {
    LabeledContent(title) {
      DatePicker(title, selection: $value, displayedComponents: .hourAndMinute)
        .labelsHidden()
        .datePickerStyle(.field)
        .fixedSize()
    }
  }
}

private struct OptionalNumberField: View {
  var title: String
  var suffix: String?
  var minimum: Double
  var validity: (Bool) -> Void
  @Binding var value: Double?
  @State private var text: String
  @State private var error: String?
  @State private var isEnabled: Bool
  @FocusState private var isFocused: Bool

  init(
    _ title: String,
    value: Binding<Double?>,
    suffix: String? = nil,
    minimum: Double = 0,
    validity: @escaping (Bool) -> Void = { _ in }
  ) {
    self.title = title
    self.suffix = suffix
    self.minimum = minimum
    self.validity = validity
    self._value = value
    self._text = State(initialValue: Self.display(value.wrappedValue))
    self._isEnabled = State(initialValue: value.wrappedValue != nil)
  }

  var body: some View {
    LabeledContent(title) {
      VStack(alignment: .trailing, spacing: 3) {
        HStack(spacing: 6) {
          if isEnabled {
            TextField("", text: $text)
              .focused($isFocused)
              .textFieldStyle(.roundedBorder)
              .multilineTextAlignment(.trailing)
              .lineLimit(1)
              .frame(width: 128)
              .onChange(of: text) { _, newValue in validate(newValue) }
              .onSubmit { normalize() }
            if let suffix {
              Text(suffix)
                .foregroundStyle(.secondary)
                .fixedSize()
            }
          } else {
            Text("不限制")
              .foregroundStyle(.secondary)
              .frame(width: 128, alignment: .trailing)
          }
          Toggle("限制 \(title)", isOn: $isEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        if let error {
          Text(error)
            .font(.caption2)
            .foregroundStyle(.red)
            .fixedSize()
        }
      }
    }
    .onChange(of: isFocused) { _, focused in
      if !focused {
        normalize()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { isEnabled = false }
      }
    }
    .onChange(of: value) { _, newValue in
      if !isFocused {
        text = Self.display(newValue)
        isEnabled = newValue != nil
      }
    }
    .onChange(of: isEnabled) { _, enabled in
      if enabled {
        if value == nil {
          let initialValue = minimum > 0 ? minimum : 0
          value = initialValue
          text = Self.display(initialValue)
        }
      } else {
        value = nil
        text = ""
        setError(nil)
      }
    }
    .onDisappear { validity(true) }
  }

  private func validate(_ rawValue: String) {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      value = nil
      setError(nil)
      return
    }
    guard let parsed = Self.parse(trimmed), parsed.isFinite, parsed >= minimum else {
      setError(minimum > 0 ? "请输入不小于 \(Self.display(minimum)) 的数字" : "请输入非负数字")
      return
    }
    value = parsed
    setError(nil)
  }

  private func normalize() {
    if error == nil { text = Self.display(value) }
  }

  private func setError(_ message: String?) {
    error = message
    validity(message == nil)
  }

  fileprivate static func parse(_ value: String) -> Double? {
    Double(value.replacingOccurrences(of: ",", with: "."))
  }

  fileprivate static func display(_ value: Double?) -> String {
    guard let value else { return "" }
    return display(value)
  }

  fileprivate static func display(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
  }
}

private struct RequiredNumberField: View {
  var title: String
  var suffix: String?
  var minimum: Double
  var validity: (Bool) -> Void
  @Binding var value: Double
  @State private var text: String
  @State private var error: String?
  @FocusState private var isFocused: Bool

  init(
    _ title: String,
    value: Binding<Double>,
    suffix: String? = nil,
    minimum: Double = 0,
    validity: @escaping (Bool) -> Void = { _ in }
  ) {
    self.title = title
    self.suffix = suffix
    self.minimum = minimum
    self.validity = validity
    self._value = value
    self._text = State(initialValue: OptionalNumberField.display(value.wrappedValue))
  }

  var body: some View {
    LabeledContent(title) {
      VStack(alignment: .trailing, spacing: 3) {
        HStack(spacing: 6) {
          TextField("", text: $text)
            .focused($isFocused)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .frame(width: 128)
            .onChange(of: text) { _, newValue in validate(newValue) }
            .onSubmit { normalize() }
          if let suffix {
            Text(suffix)
              .foregroundStyle(.secondary)
              .fixedSize()
          }
        }
        if let error {
          Text(error)
            .font(.caption2)
            .foregroundStyle(.red)
            .fixedSize()
        }
      }
    }
    .onChange(of: isFocused) { _, focused in
      if !focused { normalize() }
    }
    .onChange(of: value) { _, newValue in
      if !isFocused { text = OptionalNumberField.display(newValue) }
    }
    .onDisappear { validity(true) }
  }

  private func validate(_ rawValue: String) {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = OptionalNumberField.parse(trimmed), parsed.isFinite, parsed >= minimum else {
      setError(trimmed.isEmpty ? "此项不能为空" : minimum > 0 ? "请输入不小于 \(OptionalNumberField.display(minimum)) 的数字" : "请输入非负数字")
      return
    }
    value = parsed
    setError(nil)
  }

  private func normalize() {
    if error == nil { text = OptionalNumberField.display(value) }
  }

  private func setError(_ message: String?) {
    error = message
    validity(message == nil)
  }
}

private struct OptionalIntegerField: View {
  var title: String
  var suffix: String?
  var minimum: Int
  var defaultValue: Int
  var validity: (Bool) -> Void
  @Binding var value: Int?
  @State private var text: String
  @State private var error: String?
  @State private var isEnabled: Bool
  @FocusState private var isFocused: Bool

  init(
    _ title: String,
    value: Binding<Int?>,
    suffix: String? = nil,
    minimum: Int = 0,
    defaultValue: Int? = nil,
    validity: @escaping (Bool) -> Void = { _ in }
  ) {
    self.title = title
    self.suffix = suffix
    self.minimum = minimum
    self.defaultValue = max(minimum, defaultValue ?? minimum)
    self.validity = validity
    self._value = value
    self._text = State(initialValue: value.wrappedValue.map(String.init) ?? "")
    self._isEnabled = State(initialValue: value.wrappedValue != nil)
  }

  var body: some View {
    LabeledContent(title) {
      VStack(alignment: .trailing, spacing: 3) {
        HStack(spacing: 6) {
          if isEnabled {
            TextField("", text: $text)
              .focused($isFocused)
              .textFieldStyle(.roundedBorder)
              .multilineTextAlignment(.trailing)
              .lineLimit(1)
              .frame(width: 128)
              .onChange(of: text) { _, newValue in validate(newValue) }
              .onSubmit { normalize() }
            if let suffix {
              Text(suffix)
                .foregroundStyle(.secondary)
                .fixedSize()
            }
          } else {
            Text("不限制")
              .foregroundStyle(.secondary)
              .frame(width: 128, alignment: .trailing)
          }
          Toggle("限制 \(title)", isOn: $isEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        if let error {
          Text(error)
            .font(.caption2)
            .foregroundStyle(.red)
            .fixedSize()
        }
      }
    }
    .onChange(of: isFocused) { _, focused in
      if !focused {
        normalize()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { isEnabled = false }
      }
    }
    .onChange(of: value) { _, newValue in
      if !isFocused {
        text = newValue.map(String.init) ?? ""
        isEnabled = newValue != nil
      }
    }
    .onChange(of: isEnabled) { _, enabled in
      if enabled {
        if value == nil {
          value = defaultValue
          text = String(defaultValue)
        }
      } else {
        value = nil
        text = ""
        setError(nil)
      }
    }
    .onDisappear { validity(true) }
  }

  private func validate(_ rawValue: String) {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      value = nil
      setError(nil)
      return
    }
    guard let parsed = Int(trimmed), parsed >= minimum else {
      setError(minimum > 0 ? "请输入不小于 \(minimum) 的整数" : "请输入非负整数")
      return
    }
    value = parsed
    setError(nil)
  }

  private func normalize() {
    if error == nil { text = value.map(String.init) ?? "" }
  }

  private func setError(_ message: String?) {
    error = message
    validity(message == nil)
  }
}

private struct RequiredIntegerField: View {
  var title: String
  var suffix: String?
  var minimum: Int
  var maximum: Int?
  var showsStepper: Bool
  var validity: (Bool) -> Void
  @Binding var value: Int
  @State private var text: String
  @State private var error: String?
  @FocusState private var isFocused: Bool

  init(
    _ title: String,
    value: Binding<Int>,
    suffix: String? = nil,
    minimum: Int = 0,
    maximum: Int? = nil,
    showsStepper: Bool = false,
    validity: @escaping (Bool) -> Void = { _ in }
  ) {
    self.title = title
    self.suffix = suffix
    self.minimum = minimum
    self.maximum = maximum
    self.showsStepper = showsStepper
    self.validity = validity
    self._value = value
    self._text = State(initialValue: String(value.wrappedValue))
  }

  var body: some View {
    LabeledContent(title) {
      VStack(alignment: .trailing, spacing: 3) {
        HStack(spacing: 6) {
          TextField("", text: $text)
            .focused($isFocused)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .frame(width: 128)
            .onChange(of: text) { _, newValue in validate(newValue) }
            .onSubmit { normalize() }
          if showsStepper, let maximum {
            Stepper("", value: $value, in: minimum...maximum)
              .labelsHidden()
              .fixedSize()
          }
          if let suffix {
            Text(suffix)
              .foregroundStyle(.secondary)
              .fixedSize()
          }
        }
        if let error {
          Text(error)
            .font(.caption2)
            .foregroundStyle(.red)
            .fixedSize()
        }
      }
    }
    .onChange(of: isFocused) { _, focused in
      if !focused { normalize() }
    }
    .onChange(of: value) { _, newValue in
      if !isFocused { text = String(newValue) }
    }
    .onDisappear { validity(true) }
  }

  private func validate(_ rawValue: String) {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = Int(trimmed), parsed >= minimum, maximum.map({ parsed <= $0 }) ?? true else {
      let rangeText = maximum.map { "请输入 \(minimum) 至 \($0) 的整数" } ?? "请输入不小于 \(minimum) 的整数"
      setError(trimmed.isEmpty ? "此项不能为空" : rangeText)
      return
    }
    value = parsed
    setError(nil)
  }

  private func normalize() {
    if error == nil { text = String(value) }
  }

  private func setError(_ message: String?) {
    error = message
    validity(message == nil)
  }
}

struct BrushDownloaderTransferPresentation {
  let transfer: BrushDownloaderTransfer?

  var downloadedText: String {
    guard transfer?.available == true, let value = transfer?.downloadedBytes else { return "—" }
    return ByteText.size(value)
  }

  var uploadedText: String {
    guard transfer?.available == true, let value = transfer?.uploadedBytes else { return "—" }
    return ByteText.size(value)
  }

  var ratioText: String {
    guard
      transfer?.available == true,
      let downloaded = transfer?.downloadedBytes,
      let uploaded = transfer?.uploadedBytes
    else { return "—" }
    if downloaded == 0 { return uploaded > 0 ? "∞" : "0.00" }
    let ratio = transfer?.overallRatio ?? Double(uploaded) / Double(downloaded)
    return String(format: "%.2f", ratio)
  }

  var sourceDescription: String {
    guard let transfer else { return "下载器累计传输统计暂不可用" }
    return "直接读取自 \(transfer.downloaderName) 的累计传输统计"
  }

  var warningText: String? {
    guard let transfer else { return "下载器累计统计暂不可用" }
    return transfer.available ? nil : "\(transfer.downloaderName) 累计统计暂不可用"
  }

  var errorHelp: String {
    transfer?.error ?? warningText ?? sourceDescription
  }
}

enum ByteText {
  static func size(_ value: Int) -> String {
    if value == 0 { return "0 KB" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    return formatter.string(fromByteCount: Int64(value))
  }

  static func speed(_ value: Int) -> String {
    "\(size(value))/s"
  }
}
