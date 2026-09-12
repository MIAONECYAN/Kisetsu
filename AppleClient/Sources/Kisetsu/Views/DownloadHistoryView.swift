import SwiftUI

enum DesktopTaskHistoryMode: Equatable {
  case active
  case all
}

struct DownloadHistoryView: View {
  @EnvironmentObject private var store: AppStore
  var mode: DesktopTaskHistoryMode = .all
  @Binding var taskSection: DesktopTaskSection
  @State private var pendingAction: HistoryPendingAction?
  @State private var showingActionConfirmation = false
  @State private var showingArchivedHistory = false

  var body: some View {
    VStack(spacing: 0) {
      historyToolbar

      if store.history.isEmpty {
        ContentUnavailableView(emptyTitle, systemImage: mode == .active ? "arrow.down.circle" : "clock.arrow.circlepath")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if historyItems.isEmpty {
        ContentUnavailableView("归档记录已隐藏", systemImage: "archivebox")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(historyItems, id: \.id) { item in
            DownloadHistoryRow(
              item: item,
              isLoading: store.historyManagementIDs.contains(item.id),
              manage: { action in
                Task { await store.manageHistory(item, action: action) }
              },
              organize: {
                Task { await store.previewHistoryItem(item) }
              },
              confirm: { action in
                confirm(action)
              }
            )
            if item.id != historyItems.last?.id { Divider() }
          }
          }
          .padding(.horizontal, KisetsuStyle.pagePadding)
        }
      }
    }
    .alert(pendingAction?.title ?? "确认操作？", isPresented: $showingActionConfirmation) {
      Button(pendingAction?.confirmTitle ?? "确认", role: .destructive) {
        guard let pendingAction else { return }
        run(pendingAction)
        self.pendingAction = nil
      }
      Button("取消", role: .cancel) {
        pendingAction = nil
      }
    } message: {
      Text(pendingAction?.message ?? "")
    }
    .task {
      await store.loadHistory(silent: true)
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(10))
        } catch {
          return
        }
        guard !store.isLoading else { continue }
        await store.loadHistory(silent: true)
      }
    }
  }

  private var historyToolbar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        historyScopePicker
        Spacer(minLength: 500)
        historyActions
      }
      .overlay {
        DesktopTaskSectionPicker(selection: $taskSection)
      }

      VStack(spacing: 10) {
        DesktopTaskSectionPicker(selection: $taskSection)
        HStack(spacing: 10) {
          historyScopePicker
          Spacer(minLength: 12)
          historyActions
        }
      }
    }
    .appToolbarSurface()
  }

  private var historyScopePicker: some View {
    Picker("动漫范围", selection: $store.selectedHistorySubscriptionID) {
      Text(mode == .active ? "全部任务" : "全部历史").tag(nil as Int?)
      ForEach(store.subscriptions) { subscription in
        Text(subscription.name).tag(Optional(subscription.id))
      }
    }
    .labelsHidden()
    .frame(width: 190)
    .onChange(of: store.selectedHistorySubscriptionID) {
      Task { await store.loadHistory() }
    }
    .help("按动漫筛选\(mode == .active ? "进行中的任务" : "下载历史")")
  }

  @ViewBuilder
  private var historyActions: some View {
    HStack(spacing: 8) {
      Button {
        Task { await store.loadHistory() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .disabled(store.isLoading)
      .help(mode == .active ? "刷新任务" : "刷新历史")
      .accessibilityLabel(mode == .active ? "刷新任务" : "刷新历史")

      if mode == .all {
        cleanupMenu

        Button {
          showingArchivedHistory.toggle()
        } label: {
          Image(systemName: showingArchivedHistory ? "archivebox.fill" : "archivebox")
        }
        .disabled(archivedHistoryCount == 0)
        .help(archiveHelp)
        .accessibilityLabel(showingArchivedHistory ? "隐藏归档" : "显示归档")
      }
    }
  }

  private var cleanupMenu: some View {
    Menu {
      Button(role: .destructive) {
        confirm(
          HistoryPendingAction(
            title: "清空下载历史？",
            message: "将清空\(clearScopeName)的下载历史数据库记录，不会删除原下载器任务或文件。关联订阅的匹配状态会回到新匹配。",
            confirmTitle: "清空记录",
            kind: .clearDownload(deleteTasks: false, deleteFiles: false)
          )
        )
      } label: {
        Label("只清空记录", systemImage: "xmark.bin")
      }

      Button(role: .destructive) {
        confirm(
          HistoryPendingAction(
            title: "清空并删除下载器任务？",
            message: "将清空\(clearScopeName)的下载历史，并尝试删除原下载器中的对应任务；已下载文件会保留。",
            confirmTitle: "清空并删任务",
            kind: .clearDownload(deleteTasks: true, deleteFiles: false)
          )
        )
      } label: {
        Label("清空并删任务", systemImage: "trash")
      }

      Button(role: .destructive) {
        confirm(
          HistoryPendingAction(
            title: "清空并删除文件？",
            message: "将清空\(clearScopeName)的下载历史，并请求原下载器删除对应任务和文件。此操作不可恢复。",
            confirmTitle: "删除任务和文件",
            kind: .clearDownload(deleteTasks: true, deleteFiles: true)
          )
        )
      } label: {
        Label("清空并删文件", systemImage: "trash.slash")
      }

      Divider()

      Button(role: .destructive) {
        confirm(
          HistoryPendingAction(
            title: "清空全部历史？",
            message: "将清空下载历史、订阅匹配/刷新状态、整理预览和整理执行历史。订阅规则、订阅级番剧信息和整理规则会保留。",
            confirmTitle: "清空全部",
            kind: .clearAll
          )
        )
      } label: {
        Label("清空全部历史", systemImage: "eraser")
      }
    } label: {
      Image(systemName: "eraser")
    }
    .disabled(store.isLoading)
    .help("清理下载历史")
    .accessibilityLabel("清理下载历史")
  }

  private var archiveHelp: String {
    if showingArchivedHistory {
      return "隐藏 \(archivedHistoryCount) 条已整理并移除或已移除任务的历史"
    }
    return "显示 \(archivedHistoryCount) 条已整理并移除或已移除任务的历史"
  }

  private var clearScopeName: String {
    if store.selectedHistorySubscriptionID != nil {
      return "当前订阅"
    }
    return "全部"
  }

  private var historyItems: [DownloadHistory] {
    store.history.filter { item in
      (mode == .all || isActive(item))
        && (showingArchivedHistory || !isArchived(item))
    }
  }

  private var emptyTitle: String {
    mode == .active ? "当前没有进行中的任务" : "暂无下载历史"
  }

  private func isActive(_ item: DownloadHistory) -> Bool {
    !["deleted", "organized_task_removed", "dry_run"].contains(item.status)
      && (item.qbittorrent?.matched == true || item.status == "downloading" || item.status == "paused")
  }

  private var archivedHistoryCount: Int {
    store.history.filter { isArchived($0) }.count
  }

  private func isArchived(_ item: DownloadHistory) -> Bool {
    if item.status == "organized_task_removed" || item.status == "deleted" {
      return true
    }
    if item.taskStatus == "已整理并移除任务" || item.taskStatus == "已从 qBittorrent 移除" || item.taskStatus == "已从下载器移除" {
      return true
    }
    if let derived = item.derivedStatus,
       derived == "已整理并移除任务" || derived == "已从 qBittorrent 移除" {
      return true
    }
    return false
  }

  private func confirm(_ action: HistoryPendingAction) {
    pendingAction = action
    showingActionConfirmation = true
  }

  private func run(_ action: HistoryPendingAction) {
    switch action.kind {
    case .manage(let item, let managementAction):
      Task { await store.manageHistory(item, action: managementAction) }
    case .deleteRecord(let item):
      Task { await store.deleteHistoryRecord(item) }
    case .clearDownload(let deleteTasks, let deleteFiles):
      Task { await store.clearDownloadHistory(deleteQbittorrentTasks: deleteTasks, deleteFiles: deleteFiles) }
    case .clearAll:
      Task { await store.clearAllHistory() }
    }
  }
}

private struct HistoryPendingAction {
  var title: String
  var message: String
  var confirmTitle: String
  var kind: HistoryPendingKind
}

private enum HistoryPendingKind {
  case manage(DownloadHistory, String)
  case deleteRecord(DownloadHistory)
  case clearDownload(deleteTasks: Bool, deleteFiles: Bool)
  case clearAll
}

private struct DownloadHistoryRow: View {
  @EnvironmentObject private var store: AppStore
  var item: DownloadHistory
  var isLoading: Bool
  var manage: (String) -> Void
  var organize: () -> Void
  var confirm: (HistoryPendingAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(item.title)
          .font(.headline)
        Spacer()
        Text(item.derivedStatus ?? StatusLabels.download(item.status))
          .foregroundStyle(.secondary)
      }
      HStack {
        Text(store.siteLabel(for: item.source))
        Text(AppRelativeTime.concise(item.createdAt))
        Text(item.derivedStatusDetail ?? "整理：\(item.organizeStatus)")
        Text("\(item.downloaderType == "transmission" ? "Transmission" : "qBittorrent")：\(item.taskStatus)")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if let progress = item.qbittorrent {
        VStack(alignment: .leading, spacing: 4) {
          if let value = progress.progress {
            ProgressView(value: min(max(value, 0), 1))
              .frame(maxWidth: 360)
          }
          Text(progress.message)
            .font(.caption)
            .foregroundStyle(progress.matched ? Color.secondary : Color.orange)
        }
      }

      HStack(spacing: 8) {
        Button {
          manage("pause")
        } label: {
          Label("暂停", systemImage: "pause.fill")
        }
        .disabled(isLoading || !canManageTask || isPaused)
        .help("暂停原下载器中的对应任务")

        Button {
          manage("resume")
        } label: {
          Label("恢复", systemImage: "play.fill")
        }
        .disabled(isLoading || !canManageTask || !isPaused)
        .help("恢复原下载器中的对应任务")

        Button {
          confirm(
            HistoryPendingAction(
              title: "删除下载器任务？",
              message: "这会从原下载器删除任务，但不会删除已下载文件。",
              confirmTitle: "删除任务",
              kind: .manage(item, "delete")
            )
          )
        } label: {
          Label("删任务", systemImage: "trash")
        }
        .disabled(isLoading || !canManageTask)
        .help("只删除下载器任务，不删除文件")

        Button {
          confirm(
            HistoryPendingAction(
              title: "删除任务和文件？",
              message: "这会从原下载器删除任务，并请求原下载器删除对应文件。此操作不可恢复。",
              confirmTitle: "删除任务和文件",
              kind: .manage(item, "delete_files")
            )
          )
        } label: {
          Label("删任务和文件", systemImage: "trash.slash")
        }
        .disabled(isLoading || !canManageTask)
        .help("删除下载器任务和对应文件")

        Button {
          confirm(
            HistoryPendingAction(
              title: "重新添加下载？",
              message: "这会使用历史里的下载链接重新添加到原下载器。",
              confirmTitle: "重新添加",
              kind: .manage(item, "readd")
            )
          )
        } label: {
          Label("重新添加", systemImage: "arrow.clockwise.circle")
        }
        .disabled(isLoading || item.downloadUrl == nil)
        .help("重新把这条历史记录添加到原下载器")

        Button {
          organize()
        } label: {
          Label("整理", systemImage: "wand.and.stars")
        }
        .disabled(isLoading || !canOrganize)
        .help(canOrganize ? "识别番剧信息并打开可编辑整理预览" : organizeBlockReason)
        .accessibilityLabel("手动整理《\(item.title)》")
        .accessibilityIdentifier("history.organize.\(item.id)")

        Button {
          confirm(
            HistoryPendingAction(
              title: "删除这条记录？",
              message: "只删除 Kisetsu 的下载历史记录，不会删除原下载器任务或文件。若记录关联订阅，对应匹配会回到新匹配。",
              confirmTitle: "删除记录",
              kind: .deleteRecord(item)
            )
          )
        } label: {
          Label("删记录", systemImage: "xmark.bin")
        }
        .disabled(isLoading)
        .help("只删除 Kisetsu 数据库里的下载记录")
      }
      .font(.caption)
      .buttonStyle(.bordered)
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
  }

  private var canManageTask: Bool {
    !["dry_run", "deleted", "organized_task_removed"].contains(item.status)
  }

  private var isPaused: Bool {
    if let state = item.qbittorrent?.state {
      return ["pausedDL", "pausedUP", "stoppedDL", "stoppedUP"].contains(state)
    }
    return item.status == "paused"
  }

  private var canOrganize: Bool {
    if let organizeAvailable = item.organizeAvailable {
      return organizeAvailable
    }
    return item.organizeStatus != "已整理" &&
      !["dry_run", "deleted", "organized", "organized_task_removed", "seeding_stopped"].contains(item.status) &&
      item.qbittorrent?.matched == true &&
      (item.qbittorrent?.progress ?? 0) >= 0.999
  }

  private var organizeBlockReason: String {
    item.organizeBlockReason ?? "任务尚未完成、未可靠映射或源文件不可访问。"
  }
}
