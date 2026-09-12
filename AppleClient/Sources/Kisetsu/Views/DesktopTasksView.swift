import SwiftUI

enum DesktopTaskSection: String, CaseIterable, Identifiable {
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

struct DesktopTasksView: View {
  @EnvironmentObject private var store: AppStore
  @State private var section: DesktopTaskSection

  init() {
    let restored = switch DesktopDebugConfiguration.initialSection {
    case "history": DesktopTaskSection.history
    case "organize": DesktopTaskSection.organized
    default: DesktopTaskSection.active
    }
    _section = State(initialValue: restored)
  }

  var body: some View {
    VStack(spacing: 0) {
      switch section {
      case .active:
        DownloadHistoryView(mode: .active, taskSection: $section)
      case .history:
        DownloadHistoryView(mode: .all, taskSection: $section)
      case .pending:
        taskSectionHeader
        DesktopPendingTasksView()
      case .organized:
        taskSectionHeader
        OrganizePreviewView()
      }
    }
    .onChange(of: store.requestedTaskSection, initial: true) { _, requested in
      guard let requested, let destination = DesktopTaskSection(rawValue: requested) else { return }
      section = destination
      store.requestedTaskSection = nil
    }
  }

  private var taskSectionHeader: some View {
    DesktopTaskSectionPicker(selection: $section)
      .frame(maxWidth: .infinity)
      .appToolbarSurface()
  }
}

struct DesktopTaskSectionPicker: View {
  @Binding var selection: DesktopTaskSection

  var body: some View {
    Picker("任务页面", selection: $selection) {
      ForEach(DesktopTaskSection.allCases) { item in
        Text(item.title).tag(item)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(width: 440)
  }
}

private struct DesktopPendingTasksView: View {
  @EnvironmentObject private var store: AppStore
  @State private var preparingTargetID: String?

  var body: some View {
    Group {
      if store.overview == nil {
        ContentUnavailableView("待整理状态暂不可用", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate",
          description: Text("请刷新后重试"))
      } else if pendingItems.isEmpty {
        ContentUnavailableView(
          "没有待整理项目",
          systemImage: "folder.badge.gearshape",
          description: Text("下载完成并可以整理的资源会显示在这里。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(pendingItems) { item in
          HStack(alignment: .center, spacing: 14) {
            Image(systemName: "folder.badge.gearshape")
              .font(.title3)
              .foregroundStyle(.teal)
              .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
              Text(item.title)
                .font(.headline)
              if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
              if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                  .font(.caption)
                  .foregroundStyle(.tertiary)
                  .lineLimit(2)
              }
            }
            Spacer(minLength: 16)
            Button {
              present(item)
            } label: {
              if preparingTargetID == targetID(for: item) {
                ProgressView().controlSize(.small)
              } else {
                Label("整理", systemImage: "wand.and.stars")
              }
            }
            .disabled(preparingTargetID != nil || !canPresent(item))
          }
          .padding(.vertical, 7)
        }
        .listStyle(.inset)
      }
    }
    .task {
      guard !DesktopDebugConfiguration.usesPlaylistFixtures else { return }
      async let overview: Void = store.loadOverview(silent: true)
      async let history: Void = store.loadHistory(silent: true)
      _ = await (overview, history)
    }
  }

  private var pendingItems: [OverviewItem] {
    store.overview?.pendingOrganizeItems ?? []
  }

  private func present(_ item: OverviewItem) {
    guard preparingTargetID == nil else { return }
    let id = targetID(for: item)
    preparingTargetID = id
    Task {
      defer { preparingTargetID = nil }
      switch item.target.targetType {
      case "organize_preview":
        guard let rawID = item.target.targetId, let historyID = Int(rawID) else { return }
        if store.history.first(where: { $0.id == historyID }) == nil {
          await store.loadHistory(silent: true)
        }
        guard let history = store.history.first(where: { $0.id == historyID }) else { return }
        await store.previewHistoryItem(history)
      case "organize_preview_record":
        guard let rawID = item.target.targetId, let recordID = Int(rawID) else { return }
        await store.loadOrganizePreviews()
        guard let record = store.organizePreviewHistory.first(where: { $0.id == recordID }) else { return }
        store.selectPreviewRecord(record)
        store.showingBatchOrganizeSheet = true
      default:
        return
      }
    }
  }

  private func targetID(for item: OverviewItem) -> String {
    "\(item.target.targetType):\(item.target.targetId ?? item.id)"
  }

  private func canPresent(_ item: OverviewItem) -> Bool {
    guard item.target.targetId != nil else { return false }
    return item.target.targetType == "organize_preview"
      || item.target.targetType == "organize_preview_record"
  }
}
