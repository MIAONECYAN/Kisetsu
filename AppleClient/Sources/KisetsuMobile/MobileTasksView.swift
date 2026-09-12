import SwiftUI

enum MobileTaskSection: String, CaseIterable, Identifiable {
  case active
  case history
  case pending
  case organized

  var id: String { rawValue }
  var title: String {
    switch self {
    case .active: "进行中"
    case .history: "下载历史"
    case .pending: "待整理"
    case .organized: "整理记录"
    }
  }
}

struct MobileTasksView: View {
  @EnvironmentObject private var store: AppStore
  var isActive: Bool
  @State private var section = MobileTaskSection.active
  @State private var selectedTaskSubscriptionID: Int?
  @State private var pendingAction: PendingHistoryAction?
  @State private var organizeSheetTarget: MobileOrganizeSheetTarget?
  @State private var preparingOrganizeTargetID: String?
  @State private var historyManagementTarget: MobileHistoryManagementTarget?
  @State private var pendingClear: MobileHistoryClearAction?
  @State private var showingClearOrganizeConfirmation = false
  @State private var showingDeleteFailedConfirmation = false
  @State private var didPresentDebugFixtureAction = false

  init(isActive: Bool, initialSection: MobileTaskSection? = nil) {
    self.isActive = isActive
    #if DEBUG
    let requestedSection = MobileDebugConfiguration.initialTaskSection(
      environment: ProcessInfo.processInfo.environment
    )
    _section = State(initialValue: MobileTaskSection(rawValue: requestedSection ?? "") ?? .active)
    #endif
    if let initialSection { _section = State(initialValue: initialSection) }
  }

  private var activeHistory: [DownloadHistory] {
    store.history.filter { item in
      !["deleted", "organized_task_removed", "dry_run"].contains(item.status)
        && (item.qbittorrent?.matched == true || item.status == "downloading" || item.status == "paused")
    }
  }

  var body: some View {
    List {
      Section {
        MobileTaskSectionPicker(selection: $section)
      }
      .listRowBackground(Color.clear)

      if section == .active || section == .history || section == .organized {
        Section {
          Menu {
            Button("全部动漫") {
              selectedTaskSubscriptionID = nil
            }
            ForEach(taskFilterOptions) { option in
              Button {
                selectedTaskSubscriptionID = option.id
              } label: {
                if selectedTaskSubscriptionID == option.id {
                  Label(option.title, systemImage: "checkmark")
                } else {
                  Text(option.title)
                }
              }
            }
          } label: {
            LabeledContent("动漫", value: taskFilterTitle)
          }
          .accessibilityLabel("按动漫筛选")
          .accessibilityValue(taskFilterTitle)
        }
        .listRowBackground(Color.clear)
      }

      switch section {
      case .active:
        historyRows(filteredHistory(activeHistory), emptyTitle: "当前没有进行中的任务")
      case .history:
        historyRows(filteredHistory(store.history), emptyTitle: "暂无下载历史")
      case .pending:
        pendingRows
      case .organized:
        organizeRows
      }
    }
    .listStyle(.plain)
    .mobileNavigationTitle("任务")
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Menu("任务操作", systemImage: "ellipsis.circle") {
          Button("清空下载历史", systemImage: "eraser", role: .destructive) {
            pendingClear = .historyOnly
          }
          Button("清空历史并移除任务", systemImage: "trash", role: .destructive) {
            pendingClear = .historyAndTasks
          }
          Button("清空历史、任务和文件", systemImage: "trash.slash", role: .destructive) {
            pendingClear = .historyTasksAndFiles
          }
          Divider()
          Button("清空全部状态历史", systemImage: "arrow.counterclockwise", role: .destructive) {
            pendingClear = .all
          }
          Button("清空整理记录", systemImage: "folder.badge.minus", role: .destructive) {
            showingClearOrganizeConfirmation = true
          }
          Button("清除失败任务", systemImage: "trash", role: .destructive) {
            showingDeleteFailedConfirmation = true
          }
          .disabled(store.organizeFailedCount == 0)
        }
        MobileToolbarRefreshButton(target: .tasks) { await refresh() }
      }
    }
    .refreshable { await refresh() }
    .task(id: isActive) {
      #if DEBUG
      presentDebugFixtureActionIfNeeded()
      #endif
      guard isActive, MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      await refresh()
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))
        guard !Task.isCancelled, isActive else { return }
        async let history: Void = store.loadHistory(silent: true)
        async let overview: Void = store.loadOverview(silent: true)
        _ = await (history, overview)
      }
    }
    .onChange(of: selectedTaskSubscriptionID) { _, _ in
      guard isActive else { return }
      Task { await refresh() }
    }
    .alert("确认任务操作？", isPresented: Binding(
      get: { pendingAction != nil },
      set: { if !$0 { pendingAction = nil } }
    )) {
      if pendingAction?.isDestructive == true {
        Button(pendingAction?.buttonTitle ?? "确认", role: .destructive) {
          guard let pendingAction else { return }
          perform(pendingAction)
          self.pendingAction = nil
        }
      } else {
        Button(pendingAction?.buttonTitle ?? "确认") {
          guard let pendingAction else { return }
          perform(pendingAction)
          self.pendingAction = nil
        }
      }
      Button("取消", role: .cancel) { pendingAction = nil }
    } message: {
      Text(pendingAction?.message ?? "")
    }
    .alert(pendingClear?.title ?? "清空历史？", isPresented: Binding(
      get: { pendingClear != nil },
      set: { if !$0 { pendingClear = nil } }
    )) {
      Button(pendingClear?.buttonTitle ?? "清空", role: .destructive) {
        guard let action = pendingClear else { return }
        Task {
          switch action {
          case .historyOnly: await store.clearDownloadHistory()
          case .historyAndTasks: await store.clearDownloadHistory(deleteQbittorrentTasks: true)
          case .historyTasksAndFiles: await store.clearDownloadHistory(deleteQbittorrentTasks: true, deleteFiles: true)
          case .all: await store.clearAllHistory()
          }
        }
        pendingClear = nil
      }
      Button("取消", role: .cancel) { pendingClear = nil }
    } message: {
      Text(pendingClear?.message ?? "")
    }
    .alert("清空整理记录？", isPresented: $showingClearOrganizeConfirmation) {
      Button("清空", role: .destructive) { Task { await store.clearOrganizeHistory() } }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只清空 Kisetsu 的整理预览和执行记录，不删除真实媒体文件或下载任务。")
    }
    .alert(deleteFailedTitle, isPresented: $showingDeleteFailedConfirmation) {
      Button("清除失败任务", role: .destructive) {
        Task {
          await store.deleteFailedOrganizeHistory(subscriptionID: selectedTaskSubscriptionID)
          await refresh()
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只删除 Kisetsu 中状态明确为失败的整理记录，不删除媒体文件、下载文件或下载器任务。")
    }
    .sheet(item: $organizeSheetTarget, onDismiss: dismissOrganizeSheet) { target in
      switch target {
      case .history:
        MobileManualOrganizeSheet().environmentObject(store)
      case .previewRecord:
        MobileOrganizePreviewSheet().environmentObject(store)
      }
    }
    .onChange(of: store.showingManualHistoryOrganizeSheet) { _, isPresented in
      if !isPresented, organizeSheetTarget?.isHistory == true {
        organizeSheetTarget = nil
      }
    }
    .onChange(of: store.showingBatchOrganizeSheet) { _, isPresented in
      if !isPresented, organizeSheetTarget?.isPreviewRecord == true {
        organizeSheetTarget = nil
      }
    }
  }

  @ViewBuilder
  private func historyRows(_ items: [DownloadHistory], emptyTitle: String) -> some View {
    if items.isEmpty {
      ContentUnavailableView(emptyTitle, systemImage: "arrow.down.circle")
        .frame(maxWidth: .infinity, minHeight: 340)
        .listRowBackground(Color.clear)
    } else {
      ForEach(items) { item in
        MobileHistoryRow(
          item: item,
          readd: {
            pendingAction = PendingHistoryAction(
              item: item,
              action: "readd",
              buttonTitle: "重新添加",
              message: "使用原下载链接将这个任务重新提交到下载器。",
              isDestructive: false
            )
          },
          organize: { presentHistoryOrganize(item) },
          isPreparingOrganize: preparingOrganizeTargetID == MobileOrganizeSheetTarget.history(item).id,
          managementAction: historyManagementTarget?.itemID == item.id
            ? historyManagementTarget?.action
            : nil,
          deleteRecord: {
            pendingAction = PendingHistoryAction(
              item: item,
              action: "delete_record",
              buttonTitle: "删除记录",
              message: "只删除 Kisetsu 的下载记录，不删除下载器任务或文件。"
            )
          }
        )
          .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button("恢复", systemImage: "play.fill") { manageHistory(item, action: .resume) }
              .tint(.green)
              .disabled(historyManagementTarget != nil || preparingOrganizeTargetID != nil)
            Button("暂停", systemImage: "pause.fill") { manageHistory(item, action: .pause) }
              .tint(.orange)
              .disabled(historyManagementTarget != nil || preparingOrganizeTargetID != nil)
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删任务", systemImage: "trash", role: .destructive) {
              pendingAction = PendingHistoryAction(
                item: item,
                action: "delete",
                buttonTitle: "删除任务",
                message: "从下载器移除任务，但保留已下载文件。"
              )
            }
            .disabled(historyManagementTarget != nil || preparingOrganizeTargetID != nil)
            Button("删文件", systemImage: "trash.slash", role: .destructive) {
              pendingAction = PendingHistoryAction(
                item: item,
                action: "delete_files",
                buttonTitle: "删除任务和文件",
                message: "从下载器移除任务并永久删除对应文件，此操作不可恢复。"
              )
            }
            .disabled(historyManagementTarget != nil || preparingOrganizeTargetID != nil)
          }
      }
    }
  }

  @ViewBuilder
  private var pendingRows: some View {
    let items = store.overview?.pendingOrganizeItems ?? []
    if store.overview == nil {
      ContentUnavailableView("待整理状态暂不可用", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate",
        description: Text("请刷新后重试"))
        .listRowBackground(Color.clear)
    } else if items.isEmpty {
      ContentUnavailableView("没有待整理项目", systemImage: "wand.and.stars")
        .frame(maxWidth: .infinity, minHeight: 340)
        .listRowBackground(Color.clear)
    } else {
      ForEach(items) { item in
        HStack(alignment: .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 5) {
            Text(item.title).font(.headline)
            if let subtitle = item.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.tertiary) }
          }
          Spacer(minLength: 8)
          MobileTaskActionButton(
            title: "整理",
            systemImage: "wand.and.stars",
            isLoading: preparingOrganizeTargetID == pendingOrganizeTargetID(item),
            action: { presentPendingOrganize(item) }
          )
          .disabled(!canPresentPendingOrganize(item) || preparingOrganizeTargetID != nil)
          .accessibilityLabel("整理《\(item.title)》")
          .accessibilityValue(canPresentPendingOrganize(item) ? "可用" : "当前不可用")
        }
      }
    }
  }

  @ViewBuilder
  private var organizeRows: some View {
    let items = filteredOrganizeHistory(store.organizeHistory)
    if items.isEmpty {
      ContentUnavailableView("暂无整理记录", systemImage: "clock.arrow.circlepath")
        .frame(maxWidth: .infinity, minHeight: 340)
        .listRowBackground(Color.clear)
    } else {
      ForEach(items) { record in
        MobileOrganizeHistoryRow(record: record)
      }
    }
  }

  private var taskFilterOptions: [MobileTaskFilterOption] {
    let ids = Set(
      store.subscriptions.map(\.id)
        + store.history.compactMap(\.subscriptionId)
        + store.organizeHistory.compactMap(\.subscriptionId)
    ).sorted()
    return ids.map { id in
      MobileTaskFilterOption(
        id: id,
        title: store.subscriptions.first(where: { $0.id == id })?.name ?? "已删除动漫 · \(id)"
      )
    }
  }

  private var taskFilterTitle: String {
    guard let selectedTaskSubscriptionID else { return "全部动漫" }
    return taskFilterOptions.first(where: { $0.id == selectedTaskSubscriptionID })?.title
      ?? "已删除动漫 · \(selectedTaskSubscriptionID)"
  }

  private var deleteFailedTitle: String {
    let scope = selectedTaskSubscriptionID == nil ? "全部动漫" : taskFilterTitle
    return "清除\(scope)的 \(store.organizeFailedCount) 条失败任务？"
  }

  private func filteredHistory(_ items: [DownloadHistory]) -> [DownloadHistory] {
    items.filter { MobileTaskFilterPresentation.matches(subscriptionID: $0.subscriptionId, selectedID: selectedTaskSubscriptionID) }
  }

  private func filteredOrganizeHistory(_ items: [OrganizeHistoryRecord]) -> [OrganizeHistoryRecord] {
    items.filter { MobileTaskFilterPresentation.matches(subscriptionID: $0.subscriptionId, selectedID: selectedTaskSubscriptionID) }
  }

  private func refresh() async {
    guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
    store.selectedHistorySubscriptionID = selectedTaskSubscriptionID
    async let history: Void = store.loadHistory(silent: true)
    async let overview: Void = store.loadOverview(silent: true)
    async let organized: Void = store.loadOrganizeHistory(subscriptionID: selectedTaskSubscriptionID)
    _ = await (history, overview, organized)
  }

  private func perform(_ action: PendingHistoryAction) {
    Task {
      if action.action == "delete_record" {
        await store.deleteHistoryRecord(action.item)
      } else {
        await store.manageHistory(action.item, action: action.action)
      }
    }
  }

  private func manageHistory(_ item: DownloadHistory, action: MobileHistoryManagementAction) {
    guard historyManagementTarget == nil, preparingOrganizeTargetID == nil else { return }
    historyManagementTarget = MobileHistoryManagementTarget(itemID: item.id, action: action)
    Task {
      defer { historyManagementTarget = nil }
      #if DEBUG
      if MobileDebugConfiguration.usesFixturesAtRuntime {
        do {
          let updated = try await MobileTaskManagementFixture.perform(
            item, action: action,
            fails: ProcessInfo.processInfo.environment["KISETSU_MOBILE_FIXTURE_TASK_OUTCOME"] == "failed",
            latency: .seconds(2)
          )
          if let index = store.history.firstIndex(where: { $0.id == updated.id }) {
            store.history[index] = updated
          }
        } catch is CancellationError {
          return
        } catch {
          store.operationStatus = OperationStatus(
            phase: .failed, title: "模拟任务操作失败",
            detail: error.localizedDescription, updatedAt: Date()
          )
        }
        return
      }
      #endif
      await store.manageHistory(item, action: action.rawValue)
    }
  }

  private func presentHistoryOrganize(_ item: DownloadHistory) {
    guard preparingOrganizeTargetID == nil, historyManagementTarget == nil else { return }
    let target = MobileOrganizeSheetTarget.history(item)
    preparingOrganizeTargetID = target.id
    Task {
      defer { preparingOrganizeTargetID = nil }
      #if DEBUG
      if MobileDebugConfiguration.usesFixturesAtRuntime {
        do { try await Task.sleep(for: .milliseconds(600)) }
        catch { return }
        store.prepareManualHistoryOrganizeFixture(item)
        organizeSheetTarget = target
        return
      }
      #endif
      await store.previewHistoryItem(item)
      if store.manualOrganizeHistoryItem?.id == item.id,
         store.showingManualHistoryOrganizeSheet {
        organizeSheetTarget = target
      }
    }
  }

  private func presentPendingOrganize(_ item: OverviewItem) {
    guard preparingOrganizeTargetID == nil else { return }
    let targetID = pendingOrganizeTargetID(item)
    preparingOrganizeTargetID = targetID
    Task {
      defer { preparingOrganizeTargetID = nil }
      switch MobileTaskOrganizeRoute.resolve(targetType: item.target.targetType) {
      case .history:
        guard let historyIDText = item.target.targetId,
              let historyID = Int(historyIDText) else { return }
        if store.history.first(where: { $0.id == historyID }) == nil {
          await store.loadHistory(silent: true)
        }
        guard let history = store.history.first(where: { $0.id == historyID }) else { return }
        #if DEBUG
        if MobileDebugConfiguration.usesFixturesAtRuntime {
          store.prepareManualHistoryOrganizeFixture(history)
          organizeSheetTarget = .history(history)
          return
        }
        #endif
        await store.previewHistoryItem(history)
        if store.manualOrganizeHistoryItem?.id == history.id,
           store.showingManualHistoryOrganizeSheet {
          organizeSheetTarget = .history(history)
        }
      case .previewRecord:
        guard let recordIDText = item.target.targetId,
              let recordID = Int(recordIDText) else { return }
        await store.loadOrganizePreviews()
        guard let record = store.organizePreviewHistory.first(where: { $0.id == recordID }) else { return }
        store.selectPreviewRecord(record)
        store.showingBatchOrganizeSheet = true
        organizeSheetTarget = .previewRecord(recordID)
      case nil:
        return
      }
    }
  }

  private func pendingOrganizeTargetID(_ item: OverviewItem) -> String {
    "\(item.target.targetType):\(item.target.targetId ?? item.id)"
  }

  private func canPresentPendingOrganize(_ item: OverviewItem) -> Bool {
    guard item.target.targetId != nil else { return false }
    return MobileTaskOrganizeRoute.resolve(targetType: item.target.targetType) != nil
  }

  private func dismissOrganizeSheet() {
    if store.showingManualHistoryOrganizeSheet {
      store.cancelManualHistoryOrganize()
    }
    store.showingBatchOrganizeSheet = false
    organizeSheetTarget = nil
  }

  #if DEBUG
  private func presentDebugFixtureActionIfNeeded() {
    guard !didPresentDebugFixtureAction,
          MobileDebugConfiguration.usesFixturesAtRuntime,
          let action = MobileDebugConfiguration.fixtureTaskAction(
            environment: ProcessInfo.processInfo.environment
          ),
          let item = store.history.first(where: { $0.id == 7003 }) else { return }
    didPresentDebugFixtureAction = true
    switch action {
    case "readd":
      pendingAction = PendingHistoryAction(
        item: item,
        action: "readd",
        buttonTitle: "重新添加",
        message: "使用原下载链接将这个任务重新提交到下载器。",
        isDestructive: false
      )
    case "organize":
      presentHistoryOrganize(item)
    case "pause-pending":
      manageHistory(item, action: .pause)
    case "resume-pending":
      manageHistory(item, action: .resume)
    case "delete-failed":
      showingDeleteFailedConfirmation = true
    default:
      break
    }
  }
  #endif
}

private struct MobileTaskFilterOption: Identifiable {
  var id: Int
  var title: String
}

private struct MobileTaskSectionPicker: View {
  @Binding var selection: MobileTaskSection

  var body: some View {
    HStack(spacing: 2) {
      ForEach(MobileTaskSection.allCases) { section in
        Button {
          selection = section
        } label: {
          Text(section.title)
            .font(.caption.weight(selection == section ? .semibold : .medium))
            .foregroundStyle(selection == section ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
              selection == section ? Color.primary.opacity(0.09) : Color.clear,
              in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == section ? .isSelected : [])
      }
    }
    .padding(4)
    .glassEffect(.regular, in: .rect(cornerRadius: 20))
  }
}

private struct MobileTaskActionButton: View {
  var title: String
  var systemImage: String
  var isLoading = false
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Group {
        if isLoading {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: systemImage)
        }
      }
      .font(.system(size: MobileTaskActionPresentation.symbolSize, weight: .semibold))
      .frame(
        width: MobileTaskActionPresentation.visibleSize,
        height: MobileTaskActionPresentation.visibleSize
      )
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .controlSize(.small)
    .frame(
      width: MobileTaskActionPresentation.hitTargetSize,
      height: MobileTaskActionPresentation.hitTargetSize
    )
    .accessibilityLabel(title)
  }
}

enum MobileTaskActionPresentation {
  static let symbolSize: CGFloat = 14
  static let visibleSize: CGFloat = 32
  static let hitTargetSize: CGFloat = 44
}

enum MobileHistoryTransferPresentation {
  private static let terminalStatuses: Set<String> = [
    "completed",
    "cancelled",
    "canceled",
    "dry_run",
    "deleted",
    "error",
    "organized",
    "organized_task_removed",
    "seeding_stopped",
  ]

  private static let completedTaskStates: Set<String> = [
    "uploading",
    "seeding",
    "completed",
    "complete",
    "stalledup",
    "pausedup",
    "stoppedup",
    "queuedup",
    "checkingup",
    "forcedup",
  ]

  static func showsLiveMetrics(for item: DownloadHistory) -> Bool {
    guard let task = item.qbittorrent else { return false }
    let status = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !terminalStatuses.contains(status) else { return false }
    if let progress = task.progress, progress >= 0.999 { return false }
    if let state = task.state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
       completedTaskStates.contains(state) {
      return false
    }
    return true
  }
}

enum MobileTaskFilterPresentation {
  static func matches(subscriptionID: Int?, selectedID: Int?) -> Bool {
    guard let selectedID else { return true }
    return subscriptionID == selectedID
  }
}

enum MobileTaskOrganizeRoute: Equatable {
  case history
  case previewRecord

  static func resolve(targetType: String) -> MobileTaskOrganizeRoute? {
    switch targetType {
    case "organize_preview": .history
    case "organize_preview_record": .previewRecord
    default: nil
    }
  }
}

private struct MobileOrganizeHistoryRow: View {
  var record: OrganizeHistoryRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(record.preview.filename).font(.headline).lineLimit(2)
        Spacer()
        MobileTag(
          text: record.status,
          systemImage: record.status == "success" ? "checkmark.circle" : "exclamationmark.circle",
          tint: record.status == "success" ? Color.green : Color.orange
        )
      }
      Text(record.message).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
      Text(MobileFormat.date(record.createdAt)).font(.caption).foregroundStyle(.tertiary)
    }
  }
}

private struct PendingHistoryAction {
  var item: DownloadHistory
  var action: String
  var buttonTitle: String
  var message: String
  var isDestructive = true
}

private enum MobileOrganizeSheetTarget: Identifiable {
  case history(DownloadHistory)
  case previewRecord(Int)

  var id: String {
    switch self {
    case .history(let item): "history:\(item.id)"
    case .previewRecord(let id): "preview:\(id)"
    }
  }

  var isHistory: Bool {
    if case .history = self { return true }
    return false
  }

  var isPreviewRecord: Bool {
    if case .previewRecord = self { return true }
    return false
  }
}

private enum MobileHistoryClearAction: String, Identifiable {
  case historyOnly
  case historyAndTasks
  case historyTasksAndFiles
  case all

  var id: String { rawValue }
  var title: String {
    switch self {
    case .historyOnly: "清空下载历史？"
    case .historyAndTasks: "清空历史并移除任务？"
    case .historyTasksAndFiles: "永久删除任务和文件？"
    case .all: "清空全部状态历史？"
    }
  }
  var buttonTitle: String {
    self == .historyTasksAndFiles ? "永久删除" : "清空"
  }
  var message: String {
    switch self {
    case .historyOnly: "只清空 Kisetsu 下载历史，不操作下载器任务或文件。"
    case .historyAndTasks: "清空下载历史并从下载器移除对应任务，保留下载文件。"
    case .historyTasksAndFiles: "清空下载历史、移除下载器任务并永久删除对应文件，此操作不可恢复。"
    case .all: "清空下载、刷新等状态历史，不删除订阅规则、下载器任务或真实文件。"
    }
  }
}

private struct MobileHistoryRow: View {
  @EnvironmentObject private var store: AppStore
  var item: DownloadHistory
  var readd: () -> Void
  var organize: () -> Void
  var isPreparingOrganize: Bool
  var managementAction: MobileHistoryManagementAction?
  var deleteRecord: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Text(item.title).font(.headline).lineLimit(2)
        Spacer(minLength: 8)
        if let managementAction {
          HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text(managementAction.pendingTitle)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          Text(item.derivedStatus ?? StatusLabels.download(item.status))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if let task = item.qbittorrent {
        if let progress = task.progress {
          ProgressView(value: min(max(progress, 0), 1))
            .accessibilityLabel("下载进度")
            .accessibilityValue("\(Int(progress * 100))%")
        }
        if MobileHistoryTransferPresentation.showsLiveMetrics(for: item) {
          HStack(spacing: 10) {
            Label(MobileFormat.bytes(task.totalSize), systemImage: "externaldrive")
            Label(MobileFormat.speed(task.downloadSpeed), systemImage: "arrow.down")
            Label(MobileFormat.speed(task.uploadSpeed), systemImage: "arrow.up")
          }
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
      }
      Text([store.siteLabel(for: item.source), item.downloaderType, MobileFormat.date(item.createdAt)].joined(separator: " · "))
        .font(.caption)
        .foregroundStyle(.tertiary)
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          MobileTaskActionButton(
            title: "重新添加下载任务",
            systemImage: "arrow.clockwise",
            action: readd
          )
          .disabled(managementAction != nil || isPreparingOrganize)
          MobileTaskActionButton(
            title: "手动整理",
            systemImage: "wand.and.stars",
            isLoading: isPreparingOrganize,
            action: organize
          )
          .disabled(item.organizeAvailable == false || isPreparingOrganize || managementAction != nil)
          .accessibilityHint(item.organizeBlockReason ?? "识别番剧信息并生成整理预览")
          Spacer(minLength: 0)
          Menu {
            Button("仅删除记录", systemImage: "xmark.bin", role: .destructive, action: deleteRecord)
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: MobileTaskActionPresentation.symbolSize, weight: .semibold))
              .frame(
                width: MobileTaskActionPresentation.visibleSize,
                height: MobileTaskActionPresentation.visibleSize
              )
          }
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
          .controlSize(.small)
          .frame(
            width: MobileTaskActionPresentation.hitTargetSize,
            height: MobileTaskActionPresentation.hitTargetSize
          )
          .accessibilityLabel("更多操作")
          .disabled(managementAction != nil || isPreparingOrganize)
        }
      }
    }
    .padding(.vertical, 4)
  }
}

enum MobileHistoryManagementAction: String, Equatable {
  case pause
  case resume

  var pendingTitle: String {
    switch self {
    case .pause: "正在暂停"
    case .resume: "正在恢复"
    }
  }
}

private struct MobileHistoryManagementTarget: Equatable {
  var itemID: Int
  var action: MobileHistoryManagementAction
}

struct MobileManualOrganizeSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  private enum Step { case details, files, confirmation }
  @State private var step: Step = .details

  var body: some View {
    NavigationStack {
      Form {
        Section("下载任务") {
          Text(store.manualOrganizeHistoryItem?.title ?? "尚未选择任务")
            .font(.headline)
            .lineLimit(3)
        }

        if step == .details {
        Section("选择作品") {
          Picker("媒体类型", selection: $store.manualOrganizeMediaType) {
            Text("动画 / 剧集").tag("anime")
            Text("电影").tag("movie")
          }
          .onChange(of: store.manualOrganizeMediaType) { _, _ in store.changeManualOrganizeMediaType() }
          MobileFormTextField(label: "作品名称", prompt: "中文、日文或英文名称", text: $store.metadataQuery)
          HStack {
            Button("全部", systemImage: "magnifyingglass") { Task { await store.searchManualHistoryMetadata() } }
            if store.manualOrganizeMediaType != "movie" {
              Button("Bangumi") { Task { await store.searchManualHistoryBangumiMetadata() } }
            }
            Button("TMDB") { Task { await store.searchManualHistoryTMDBMetadata() } }
          }
          .disabled(store.manualOrganizeOperation.isRunning)

          if !store.metadataCandidates.isEmpty {
            Picker("匹配结果", selection: Binding(
              get: { store.manualOrganizeSelectedCandidateID },
              set: { store.selectManualHistoryMetadata($0) }
            )) {
              Text("不使用候选").tag(nil as String?)
              ForEach(store.metadataCandidates) { candidate in
                HStack(spacing: 10) {
                  MobilePosterImage(url: candidate.posterUrl.flatMap(URL.init(string:)), width: 40, height: 60)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.chineseTitle ?? candidate.title)
                    Text([candidate.airDate.map { String($0.prefix(4)) }, candidate.mediaType == "movie" ? "电影" : "剧集", candidate.source.uppercased()].compactMap { $0 }.joined(separator: " · "))
                      .font(.caption).foregroundStyle(.secondary)
                  }
                }
                  .tag(Optional(candidate.id))
              }
            }
            .pickerStyle(.navigationLink)
          }
          if let feedback = store.manualOrganizeOperation.feedback {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title).font(.subheadline.weight(.semibold))
                Text(feedback.detail).font(.caption).foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
          }
        }

        Section("整理信息") {
          MobileFormTextField(label: "整理名称", prompt: "目标作品名称", text: $store.mapping.showName)
            .onChange(of: store.mapping.showName) { _, _ in store.invalidateManualHistoryOrganizePreview() }
          MobileFormTextField(label: "年份", prompt: "例如：2026", text: $store.manualOrganizeYear)
            .keyboardType(.numberPad)
            .onChange(of: store.manualOrganizeYear) { _, _ in store.invalidateManualHistoryOrganizePreview() }
          MobileFormValidationMessage(message: yearValidationMessage)
          if store.manualOrganizeMediaType != "movie" {
          Stepper("季数：\(store.mapping.seasonNumber)", value: $store.mapping.seasonNumber, in: 0...99)
            .onChange(of: store.mapping.seasonNumber) { _, _ in store.invalidateManualHistoryOrganizePreview() }
          Text("季数为 0 时按特别篇目录整理。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Toggle("合集或多集任务", isOn: $store.manualOrganizeIsBatch)
            .disabled(store.manualOrganizeRequiresMultipleFiles)
            .onChange(of: store.manualOrganizeIsBatch) { _, _ in store.invalidateManualHistoryOrganizePreview() }
          if store.manualOrganizeIsBatch {
            LabeledContent("集数范围") {
              HStack {
                TextField("起始", text: $store.manualOrganizeEpisodeStart).keyboardType(.numberPad)
                Text("至").foregroundStyle(.secondary)
                TextField("结束", text: $store.manualOrganizeEpisodeEnd).keyboardType(.numberPad)
              }
              .multilineTextAlignment(.trailing)
            }
            MobileFormValidationMessage(message: episodeRangeValidationMessage)
          } else {
            MobileFormTextField(label: "集数", prompt: "例如：76", text: $store.manualOrganizeEpisodeStart)
              .keyboardType(.numberPad)
            MobileFormValidationMessage(message: episodeRangeValidationMessage)
          }
          }
          Picker("整理目标", selection: $store.manualOrganizeTargetID) {
            Text("请选择").tag(nil as Int?)
            ForEach(store.organizeTargets.filter(\.enabled)) { target in
              Text(target.name).tag(Optional(target.id))
            }
          }
          .onChange(of: store.manualOrganizeTargetID) { _, _ in store.invalidateManualHistoryOrganizePreview() }
        }
        }

        if step != .details, let preview = store.organizePreview {
          Section(step == .files ? "文件与映射" : "确认整理") {
            LabeledContent("作品", value: store.mapping.showName)
            LabeledContent("目标", value: store.organizeTargets.first { $0.id == store.manualOrganizeTargetID }?.name ?? "")
            if (preview.fileMappings ?? []).isEmpty {
              Text(URL(fileURLWithPath: preview.sourcePath).lastPathComponent)
                .font(.subheadline).textSelection(.enabled)
            }
            if (preview.fileMappings ?? []).isEmpty {
              Text([preview.showDirectory, preview.seasonDirectory, preview.filename].filter { !$0.isEmpty }.joined(separator: "/"))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
              LabeledContent("目录", value: preview.showDirectory)
            }
            ForEach(store.pendingFileMappings(for: preview)) { mapping in
              if step == .files {
                MobileOrganizeMappingEditor(mapping: mapping)
              } else if mapping.status != "skipped" {
                VStack(alignment: .leading, spacing: 4) {
                  Text(mapping.originalFilename).font(.subheadline)
                  Label(mapping.targetFilename, systemImage: "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(.secondary)
                }
              }
            }
            if let reason = preview.blockReason, !reason.isEmpty {
              Label(reason, systemImage: "exclamationmark.octagon")
                .foregroundStyle(.red)
            }
            if preview.batchMode == "single_file" {
              Picker("合集文件命名", selection: Binding(
                get: { preview.singleFileMode ?? "as_batch_file" },
                set: { store.updateSingleFileBatchMode($0) }
              )) {
                Text("保留合集").tag("as_batch_file")
                Text("集数范围").tag("episode_range")
                Text("特别篇合集").tag("specials_batch")
              }
              .disabled(step == .confirmation)
            }
          }
        }
        if step != .details, let feedback = store.manualOrganizeOperation.feedback {
          Section {
            Label(feedback.detail, systemImage: "exclamationmark.triangle")
              .font(.subheadline).foregroundStyle(.red)
          }
        }
      }
      .disabled(isBusy)
      .onChange(of: store.manualOrganizeEpisodeStart) { _, _ in store.invalidateManualHistoryOrganizePreview() }
      .onChange(of: store.manualOrganizeEpisodeEnd) { _, _ in store.invalidateManualHistoryOrganizePreview() }
      .mobileStatusNavigationTitle("手动整理")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") {
            store.cancelManualHistoryOrganize()
            dismiss()
          }
          .disabled(store.isApplyingOrganizePreview)
        }
        ToolbarItem(placement: .primaryAction) {
          if isBusy {
            ProgressView().accessibilityLabel("正在处理")
          } else if step != .details {
            Button("上一步", systemImage: "chevron.left") {
              step = step == .confirmation ? .files : .details
            }
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        HStack {
          Spacer()
          Button(primaryActionTitle) {
            Task {
              if step == .confirmation {
                await store.applyOrganizePreview()
              } else if step == .files && canApply {
                step = .confirmation
              } else {
                await store.previewManualHistoryOrganize()
                if store.organizePreview != nil { step = .files }
              }
            }
          }
          .buttonStyle(.glass)
          .controlSize(.regular)
          .frame(minHeight: 44)
          .disabled(isBusy || (step == .confirmation ? !canApply : !canPreview))
          Spacer()
        }
        .padding(.vertical, 10)
        .background(.bar)
      }
    }
    .interactiveDismissDisabled(store.isApplyingOrganizePreview)
    .onDisappear { if !store.isApplyingOrganizePreview { store.cancelManualHistoryOrganize() } }
  }

  private var isBusy: Bool { store.manualOrganizeOperation.isRunning || store.isApplyingOrganizePreview }

  private var primaryActionTitle: String {
    switch step {
    case .details: "选择文件"
    case .files: canApply ? "查看整理预览" : "更新预览"
    case .confirmation: "确认整理"
    }
  }

  private var canPreview: Bool {
    !store.mapping.showName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && store.manualOrganizeTargetID != nil
      && store.manualOrganizeHistoryItem != nil
      && yearValidationMessage == nil
      && episodeRangeValidationMessage == nil
  }

  private var yearValidationMessage: String? {
    MobileFormValidation.integerMessage(
      store.manualOrganizeYear,
      field: "首播年份",
      minimum: 0,
      allowsEmpty: true
    )
  }

  private var episodeRangeValidationMessage: String? {
    if store.manualOrganizeMediaType == "movie" { return nil }
    if let message = MobileFormValidation.integerMessage(
      store.manualOrganizeEpisodeStart,
      field: store.manualOrganizeIsBatch ? "起始集数" : "集数",
      minimum: 1,
      allowsEmpty: true
    ) {
      return message
    }
    guard store.manualOrganizeIsBatch else { return nil }
    if let message = MobileFormValidation.integerMessage(
      store.manualOrganizeEpisodeEnd,
      field: "结束集数",
      minimum: 1,
      allowsEmpty: true
    ) {
      return message
    }
    if let start = Int(store.manualOrganizeEpisodeStart.trimmingCharacters(in: .whitespacesAndNewlines)),
       let end = Int(store.manualOrganizeEpisodeEnd.trimmingCharacters(in: .whitespacesAndNewlines)), start > end {
      return "起始集数不能大于结束集数。"
    }
    return nil
  }

  private var canApply: Bool {
    store.organizePreview.map(ManualOrganizePresentation.canApply) ?? false
  }
}
