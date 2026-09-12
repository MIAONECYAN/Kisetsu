import SwiftUI

struct OrganizePreviewView: View {
  @EnvironmentObject private var store: AppStore
  @State private var selectedSubscriptionFilterID = 0
  @State private var statusFilter: OrganizeHistoryStatusFilter = .all
  @State private var searchText = ""
  @State private var showingClearConfirmation = false
  @State private var showingDeleteFailedConfirmation = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      VStack(spacing: 16) {
        historyTab
      }
        .padding(.horizontal, KisetsuStyle.pagePadding)
        .padding(.bottom, 20)
    }
    .alert("清空整理历史？", isPresented: $showingClearConfirmation) {
      Button("取消", role: .cancel) {}
      Button("清空历史", role: .destructive) {
        Task { await store.clearOrganizeHistory() }
      }
    } message: {
      Text("将清空所有整理预览和整理执行记录，不会删除真实媒体文件，也不会删除整理规则。")
    }
    .alert(deleteFailedTitle, isPresented: $showingDeleteFailedConfirmation) {
      Button("取消", role: .cancel) {}
      Button("删除失败记录", role: .destructive) {
        Task {
          await store.deleteFailedOrganizeHistory(
            subscriptionID: selectedSubscriptionFilterID == 0 ? nil : selectedSubscriptionFilterID
          )
          await loadHistory()
        }
      }
    } message: {
      Text("只删除 Kisetsu 中的失败整理记录，不会删除媒体文件、下载文件或下载器任务。")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("查看整理结果、失败原因和文件路径")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          Task {
            await loadHistory()
          }
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .disabled(store.isLoading)

        Button(role: .destructive) {
          showingDeleteFailedConfirmation = true
        } label: {
          Label("删除失败记录", systemImage: "trash")
        }
        .disabled(store.isLoading || store.organizeFailedCount == 0)

        Button(role: .destructive) {
          showingClearConfirmation = true
        } label: {
          Label("清空", systemImage: "eraser")
        }
        .disabled(store.isLoading || store.organizeHistory.isEmpty)
      }

      HStack(spacing: 10) {
        Picker("订阅", selection: $selectedSubscriptionFilterID) {
          Text("全部订阅").tag(0)
          ForEach(store.subscriptions) { subscription in
            Text(subscription.name).tag(subscription.id)
          }
        }
        .frame(width: 220)
        .onChange(of: selectedSubscriptionFilterID) { _, _ in
          Task { await loadHistory() }
        }

        Picker("状态", selection: $statusFilter) {
          ForEach(OrganizeHistoryStatusFilter.allCases) { filter in
            Text(filter.title).tag(filter)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 360)
        .onChange(of: statusFilter) { _, newValue in
          Task { await loadHistory(status: newValue.apiValue) }
        }

        TextField("搜索番剧、文件名或路径", text: $searchText)
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            Task { await loadHistory() }
          }

        Button {
          Task { await loadHistory() }
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .help("按当前条件搜索整理记录")
      }
    }
    .appToolbarSurface()
  }

  private func loadHistory(status: String? = nil) async {
    await store.loadOrganizeHistory(
      subscriptionID: selectedSubscriptionFilterID == 0 ? nil : selectedSubscriptionFilterID,
      status: status ?? statusFilter.apiValue,
      search: searchText
    )
  }

  private var deleteFailedTitle: String {
    if selectedSubscriptionFilterID == 0 {
      return "删除全部订阅的 \(store.organizeFailedCount) 条失败记录？"
    }
    let name = store.subscriptions.first(where: { $0.id == selectedSubscriptionFilterID })?.name ?? "当前订阅"
    return "删除《\(name)》的 \(store.organizeFailedCount) 条失败记录？"
  }

  private var historyTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if store.organizeHistory.isEmpty {
          ContentUnavailableView("暂无整理执行记录", systemImage: "clock.arrow.circlepath", description: Text("执行自动整理或订阅详情内整理后，这里会显示成功、跳过和失败记录。"))
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
          ForEach(store.organizeHistory) { record in
            OrganizeHistoryRow(record: record)
            Divider()
          }
        }
      }
      .padding(.top, 16)
    }
  }

}

struct ManualHistoryOrganizeSheet: View {
  @EnvironmentObject private var store: AppStore
  var close: () -> Void
  private enum Step: Int { case details, files, confirmation }
  @State private var step: Step = .details

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("手动整理 · \(stepTitle)")
            .font(.title3.weight(.semibold))
          Text(store.manualOrganizeHistoryItem?.title ?? "确认番剧信息和文件映射后再整理。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(store.manualOrganizeHistoryItem?.title ?? "")
        }
        Spacer()
        if isBusy {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding([.horizontal, .top], 22)
      .padding(.bottom, 12)

      Divider()

      Form {
        if step == .details {
        Section("选择作品") {
          Picker("媒体类型", selection: $store.manualOrganizeMediaType) {
            Text("动画 / 剧集").tag("anime")
            Text("电影").tag("movie")
          }
          .pickerStyle(.segmented)
          .onChange(of: store.manualOrganizeMediaType) { _, _ in store.changeManualOrganizeMediaType() }
          MetadataSearchControls(
            query: $store.metadataQuery,
            isLoading: store.manualOrganizeOperation.isRunning,
            onSearchAll: { Task { await store.searchManualHistoryMetadata() } },
            onSearchBangumi: { Task { await store.searchManualHistoryBangumiMetadata() } },
            onSearchTMDB: { Task { await store.searchManualHistoryTMDBMetadata() } },
            includesBangumi: store.manualOrganizeMediaType != "movie"
          )

          if store.metadataCandidates.isEmpty && !store.manualOrganizeOperation.isRunning {
            Text("没有可靠候选时可以直接编辑下方信息，再由后端生成文件映射预览。")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if !store.metadataCandidates.isEmpty {
            HStack {
              Text("匹配候选")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              Spacer()
              Button("不使用候选") {
                store.selectManualHistoryMetadata(nil)
              }
              .disabled(store.manualOrganizeSelectedCandidateID == nil)
            }
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.metadataCandidates) { candidate in
                  MetadataCandidateRow(
                    candidate: candidate,
                    isRecommended: candidate.id == store.metadataRecommendedCandidateID,
                    isSelected: candidate.id == store.manualOrganizeSelectedCandidateID,
                    actionTitle: candidate.id == store.manualOrganizeSelectedCandidateID ? "已选择" : "选择",
                    actionHelp: "使用此候选填写当前整理草稿，不会保存订阅或整理记录",
                    isActionInProgress: false,
                    actionDisabled: store.manualOrganizeOperation.isRunning,
                    onSelect: { store.selectManualHistoryMetadata(candidate.id) }
                  )
                  if candidate.id != store.metadataCandidates.last?.id {
                    Divider()
                  }
                }
              }
            }
            .frame(minHeight: 190, maxHeight: 310)
          }
          ForEach(store.metadataWarnings, id: \.self) { warning in
            Label(StatusLabels.message(warning), systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section("整理信息") {
          TextField("整理名称", text: $store.mapping.showName)
            .onChange(of: store.mapping.showName) { _, _ in
              store.invalidateManualHistoryOrganizePreview()
            }
          TextField("年份", text: $store.manualOrganizeYear, prompt: Text("可留空"))
            .onChange(of: store.manualOrganizeYear) { _, _ in
              store.invalidateManualHistoryOrganizePreview()
            }

          if store.manualOrganizeMediaType != "movie" {
          Stepper(
            "季数：\(store.mapping.seasonNumber)",
            value: $store.mapping.seasonNumber,
            in: 0...99
          )
          .onChange(of: store.mapping.seasonNumber) { _, _ in
            store.invalidateManualHistoryOrganizePreview()
          }

          Toggle("这是合集或多集任务", isOn: $store.manualOrganizeIsBatch)
            .disabled(store.manualOrganizeRequiresMultipleFiles)
            .onChange(of: store.manualOrganizeIsBatch) { _, _ in
              store.invalidateManualHistoryOrganizePreview()
            }

          if store.manualOrganizeRequiresMultipleFiles {
            Label("已根据下载记录中的集数范围锁定为多文件任务", systemImage: "rectangle.stack")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          if store.manualOrganizeIsBatch {
            LabeledContent("集数范围") {
              HStack(spacing: 8) {
                TextField("起始", text: $store.manualOrganizeEpisodeStart)
                  .frame(width: 90)
                Text("至")
                  .foregroundStyle(.secondary)
                TextField("结束", text: $store.manualOrganizeEpisodeEnd)
                  .frame(width: 90)
              }
            }
            .onChange(of: store.manualOrganizeEpisodeStart) { _, _ in
              store.invalidateManualHistoryOrganizePreview()
            }
            .onChange(of: store.manualOrganizeEpisodeEnd) { _, _ in
              store.invalidateManualHistoryOrganizePreview()
            }
            Text("合集范围可留空，后端会根据真实视频文件逐项识别；无法确认的文件不会允许提交。")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            TextField("集数", text: $store.manualOrganizeEpisodeStart, prompt: Text("例如 1"))
              .onChange(of: store.manualOrganizeEpisodeStart) { _, _ in
                store.invalidateManualHistoryOrganizePreview()
              }
          }
          }

          Picker("整理目标", selection: $store.manualOrganizeTargetID) {
            Text("请选择").tag(nil as Int?)
            ForEach(store.organizeTargets.filter(\.enabled)) { target in
              Text(target.name).tag(Optional(target.id))
            }
          }
          .onChange(of: store.manualOrganizeTargetID) { _, _ in
            store.invalidateManualHistoryOrganizePreview()
          }
        }
        }

        if let feedback = store.manualOrganizeOperation.feedback {
          Section {
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
              VStack(alignment: .leading, spacing: 3) {
                Text(feedback.title)
                  .font(.callout.weight(.semibold))
                Text(feedback.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
              Spacer()
              Button {
                store.dismissManualOrganizeFeedback()
              } label: {
                Image(systemName: "xmark")
              }
              .buttonStyle(.plain)
              .help("关闭本次错误")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(feedback.title)，\(feedback.detail)")
          }
        }

        if step != .details, let preview = store.organizePreview {
          Section {
            LabeledContent("作品", value: store.mapping.showName)
            LabeledContent("整理目标", value: store.organizeTargets.first { $0.id == store.manualOrganizeTargetID }?.name ?? "")
            Text(preview.libraryRoot)
              .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            BatchOrganizePreviewPanel(preview: preview, isEditable: step == .files)
          }
        }
      }
      .formStyle(.grouped)
      .disabled(isBusy)

      Divider()

      HStack {
        Button("取消", role: .cancel) {
          close()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(store.isApplyingOrganizePreview)
        Spacer()
        if step != .details {
          Button("上一步", systemImage: "chevron.left") {
            step = step == .confirmation ? .files : .details
          }.disabled(isBusy)
        }
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
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(isBusy || (step == .confirmation ? !canApply : !canPreview))
      }
      .padding()
    }
    .frame(minWidth: 780, idealWidth: 900, minHeight: 580, idealHeight: 700)
    .interactiveDismissDisabled(store.isApplyingOrganizePreview)
  }

  private var isBusy: Bool { store.manualOrganizeOperation.isRunning || store.isApplyingOrganizePreview }

  private var stepTitle: String {
    switch step {
    case .details: "1 / 3 · 选择作品"
    case .files: "2 / 3 · 文件映射"
    case .confirmation: "3 / 3 · 确认整理"
    }
  }

  private var primaryActionTitle: String {
    switch step {
    case .details: "选择文件"
    case .files: canApply ? "查看整理预览" : "更新预览"
    case .confirmation: "确认整理"
    }
  }

  private var canPreview: Bool {
    !store.mapping.showName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
      store.manualOrganizeTargetID != nil &&
      store.manualOrganizeHistoryItem != nil
  }

  private var canApply: Bool {
    guard let preview = store.organizePreview else { return false }
    return ManualOrganizePresentation.canApply(preview)
  }

}

struct BatchOrganizeSheet: View {
  @EnvironmentObject private var store: AppStore
  var close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("整理预览")
            .font(.title3.weight(.semibold))
          Text(store.organizePreview?.destinationPreview ?? "确认文件列表、集数和目标路径后再执行整理。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
      }
      .padding([.horizontal, .top], 22)
      .padding(.bottom, 12)

      Divider()

      if let preview = store.organizePreview {
        BatchOrganizePreviewPanel(preview: preview)
          .padding(18)
          .disabled(store.isLoading || store.isApplyingOrganizePreview)
      } else {
        ContentUnavailableView("没有整理预览", systemImage: "folder", description: Text("请先从订阅详情或概览页生成合集整理预览。"))
          .frame(minHeight: 300)
      }

      Divider()

      HStack {
        Button("取消", role: .cancel) {
          close()
        }
        .disabled(store.isApplyingOrganizePreview)
        Spacer()
        Button("更新预览", systemImage: "arrow.clockwise") {
          Task { await store.regenerateOrganizePreview() }
        }
        .disabled(store.organizePreview == nil || store.isLoading || store.isApplyingOrganizePreview)
        Button {
          Task { await store.applyOrganizePreview() }
        } label: {
          Label("执行整理", systemImage: "play.circle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canApply || store.isLoading || store.isApplyingOrganizePreview)
      }
      .padding()
    }
    .frame(minWidth: 780, idealWidth: 920, minHeight: 540, idealHeight: 680)
    .interactiveDismissDisabled(store.isApplyingOrganizePreview)
  }

  private var canApply: Bool {
    guard let preview = store.organizePreview else { return false }
    return ManualOrganizePresentation.canApply(preview)
  }
}

struct BatchOrganizePreviewPanel: View {
  @EnvironmentObject private var store: AppStore
  var preview: OrganizePreviewItem
  var isEditable = true

  private var mappings: [OrganizePreviewFileMapping] {
    store.pendingFileMappings(for: preview)
  }

  private var pendingCount: Int {
    mappings.filter { $0.status == "needs_confirmation" }.count
  }

  private var readyCount: Int {
    mappings.filter { $0.status == "ready" }.count
  }

  private var isSingleFile: Bool {
    preview.batchMode == "single_file"
  }

  private var visibleMappings: [OrganizePreviewFileMapping] {
    mappings.filter { isEditable || $0.status != "skipped" }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text(preview.mediaType == "movie" ? "电影文件" : "文件映射")
            .font(.headline)
          Text(isSingleFile ? "\(preview.showDirectory) · 单个合集文件" : "\(preview.showDirectory) · \(max(visibleMappings.count, 1)) 个文件")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if isSingleFile {
          Label("不会拆分文件", systemImage: "doc")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if pendingCount > 0 {
          Label(preview.mediaType == "movie" ? "\(pendingCount) 个文件待选择" : "\(pendingCount) 个文件需要确认集数", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
          Label("\(mappings.isEmpty && preview.canApply == true ? 1 : readyCount) 个文件可整理", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.green)
        }
      }

      if isSingleFile {
        SingleFileBatchOptions(preview: preview)
          .disabled(!isEditable)
      } else if mappings.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text(URL(fileURLWithPath: preview.sourcePath).lastPathComponent)
            .font(.callout.weight(.medium)).textSelection(.enabled)
            .help(preview.sourcePath)
          Label(preview.destinationPreview, systemImage: "arrow.turn.down.right")
            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          SubtitleMappingList(mappings: preview.subtitleMappings ?? [])
        }
      } else {
        VStack(spacing: 8) {
          HStack {
            Text("源文件与目标文件")
            Spacer()
            Text(isEditable ? "确认映射" : "确认后执行")
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(visibleMappings) { row in
                BatchOrganizeMappingRow(row: row, preview: preview, isEditable: isEditable)
                if row.id != visibleMappings.last?.id {
                  Divider()
                }
              }
            }
          }
          .frame(height: min(430, CGFloat(max(visibleMappings.count, 1)) * 148))
        }
      }
      if preview.canApply == false, let blockReason = preview.blockReason {
        Label(blockReason, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }
}

private struct SingleFileBatchOptions: View {
  @EnvironmentObject private var store: AppStore
  var preview: OrganizePreviewItem

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("这是单个合集文件，无法自动拆分为单集。")
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker("目标命名", selection: Binding {
        preview.singleFileMode ?? "as_batch_file"
      } set: { value in
        store.updateSingleFileBatchMode(value)
      }) {
        Text("按合集文件整理").tag("as_batch_file")
        Text("标记为 SxxE01-E12").tag("episode_range")
        Text("Specials / Batch").tag("specials_batch")
      }
      .pickerStyle(.segmented)
      VStack(alignment: .leading, spacing: 4) {
        Text(preview.filename)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(preview.destinationPreview)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      SubtitleMappingList(mappings: preview.subtitleMappings ?? [])
    }
  }
}

private struct BatchOrganizeMappingRow: View {
  @EnvironmentObject private var store: AppStore
  var row: OrganizePreviewFileMapping
  var preview: OrganizePreviewItem
  var isEditable = true

  private var skipped: Bool { row.status == "skipped" }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 14) {
        episodeSummary
        fileMappingDetails
          .frame(maxWidth: .infinity, alignment: .leading)
        if isEditable { mappingControls
          .frame(width: 238, alignment: .leading)
        }
      }
      .frame(minWidth: 660)

      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          episodeIdentityLabel
          Spacer(minLength: 12)
          statusLabel
        }
        fileMappingDetails
        if isEditable { mappingControls }
      }
    }
    .padding(.vertical, 10)
  }

  private var episodeIdentity: String {
    if preview.mediaType == "movie" { return "电影" }
    guard let episode = row.episodeNumber else { return "待确认" }
    return String(format: "S%02dE%02d", row.seasonNumber, episode)
  }

  private var sourceDirectory: String {
    compactDirectoryName(for: row.sourcePath)
  }

  private var targetDirectory: String {
    compactDirectoryName(for: row.targetPath)
  }

  private func compactDirectoryName(for path: String) -> String {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    return directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent
  }

  private var episodeSummary: some View {
    VStack(alignment: .leading, spacing: 7) {
      episodeIdentityLabel
      statusLabel
    }
    .frame(width: 88, alignment: .leading)
  }

  private var episodeIdentityLabel: some View {
    Text(episodeIdentity)
      .font(.title3.weight(.semibold))
      .monospacedDigit()
      .foregroundStyle(skipped ? .secondary : .primary)
      .lineLimit(1)
      .accessibilityLabel(episodeIdentity)
  }

  private var statusLabel: some View {
    Label(statusText, systemImage: statusIcon)
      .font(.caption.weight(.semibold))
      .foregroundStyle(statusColor)
      .lineLimit(1)
  }

  private var fileMappingDetails: some View {
    VStack(alignment: .leading, spacing: 8) {
      fileMappingLine(
        label: "源文件",
        systemImage: "doc",
        filename: row.originalFilename,
        directory: sourceDirectory,
        fullPath: row.sourcePath,
        isTarget: false
      )
      fileMappingLine(
        label: "目标文件",
        systemImage: "arrow.turn.down.right",
        filename: row.targetFilename,
        directory: targetDirectory,
        fullPath: row.targetPath,
        isTarget: true
      )
      if let visibleMessage {
        Label(visibleMessage, systemImage: row.status == "error" ? "xmark.octagon" : "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(row.status == "error" ? .red : .orange)
          .lineLimit(2)
      }
      SubtitleMappingList(mappings: row.subtitleMappings ?? [])
    }
  }

  private func fileMappingLine(
    label: String,
    systemImage: String,
    filename: String,
    directory: String,
    fullPath: String,
    isTarget: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        HStack(spacing: 5) {
          Image(systemName: systemImage)
          Text(label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 66, alignment: .leading)
        Text(filename)
          .font(isTarget ? .callout.weight(.semibold) : .callout.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(fullPath)
      }
      Text("目录：\(directory)")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(fullPath)
    }
  }

  private var mappingControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      if preview.mediaType != "movie" {
      HStack(spacing: 8) {
        Stepper("S\(String(format: "%02d", row.seasonNumber))", value: Binding {
          row.seasonNumber
        } set: { value in
          store.updateOrganizePreviewMapping(id: row.id, seasonNumber: value)
        }, in: 0...99)
        .disabled(skipped || row.isSpecial)
        Stepper("E\(String(format: "%02d", row.episodeNumber ?? 1))", value: Binding {
          row.episodeNumber ?? 1
        } set: { value in
          store.updateOrganizePreviewMapping(id: row.id, episodeNumber: value)
        }, in: 1...999)
        .disabled(skipped)
      }
      .monospacedDigit()
      }

      HStack(spacing: 12) {
        if preview.mediaType != "movie" {
        Toggle("特典", isOn: Binding {
          row.isSpecial
        } set: { value in
          store.updateOrganizePreviewMapping(id: row.id, isSpecial: value)
        })
        .toggleStyle(.checkbox)
        }
        Toggle("跳过", isOn: Binding {
          skipped
        } set: { value in
          store.updateOrganizePreviewMapping(id: row.id, skipped: value)
        })
        .toggleStyle(.checkbox)
      }
    }
  }

  private var visibleMessage: String? {
    guard !row.message.isEmpty, row.message != statusText, row.message != "可整理" else {
      return nil
    }
    return row.message
  }

  private var statusText: String {
    switch row.status {
    case "ready": "可整理"
    case "needs_confirmation": "需确认"
    case "skipped": "跳过"
    case "error": "错误"
    default: row.status
    }
  }

  private var statusIcon: String {
    switch row.status {
    case "ready": "checkmark.circle"
    case "needs_confirmation": "exclamationmark.triangle"
    case "skipped": "minus.circle"
    case "error": "xmark.octagon"
    default: "questionmark.circle"
    }
  }

  private var statusColor: Color {
    switch row.status {
    case "ready": .green
    case "needs_confirmation": .orange
    case "skipped": .secondary
    case "error": .red
    default: .secondary
    }
  }
}

private struct SubtitleMappingList: View {
  var mappings: [OrganizeSubtitleMapping]

  var body: some View {
    if !mappings.isEmpty {
      VStack(alignment: .leading, spacing: 5) {
        Label("\(mappings.count) 个外挂字幕将同步整理", systemImage: "captions.bubble")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        ForEach(mappings, id: \.sourcePath) { mapping in
          HStack(spacing: 8) {
            Text(mapping.originalFilename)
              .lineLimit(1)
            Image(systemName: "arrow.right")
              .font(.caption2)
              .foregroundStyle(.tertiary)
            Text(mapping.targetFilename)
              .lineLimit(1)
          }
          .font(.caption2)
          .foregroundStyle(mapping.status == "error" ? .red : .secondary)
        }
      }
      .padding(.top, 2)
    }
  }
}

private enum OrganizeHistoryStatusFilter: String, CaseIterable, Identifiable {
  case all
  case moved
  case skipped
  case error

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "全部"
    case .moved: "已整理"
    case .skipped: "已跳过"
    case .error: "失败"
    }
  }

  var apiValue: String? {
    self == .all ? nil : rawValue
  }
}

private struct OrganizeHistoryRow: View {
  var record: OrganizeHistoryRecord

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(color)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(record.preview.filename)
            .font(.body.weight(.medium))
            .lineLimit(1)
          Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
        }
        Text(record.message)
          .font(.caption)
          .foregroundStyle(record.status == "error" ? .red : .secondary)
          .lineLimit(2)
        Text("\(record.preview.showDirectory) · \(record.preview.seasonDirectory)")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(record.destinationPath)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(record.sourcePath)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
        Label(qbittorrentText, systemImage: qbittorrentIcon)
          .font(.caption2)
          .foregroundStyle(qbittorrentColor)
          .lineLimit(1)
        if record.cleanupAttempted {
          Label(cleanupText, systemImage: cleanupIcon)
            .font(.caption2)
            .foregroundStyle(cleanupColor)
            .lineLimit(1)
        }
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 4) {
        Text("#\(record.id)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Text(AppRelativeTime.concise(record.createdAt))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 8)
  }

  private var title: String {
    switch record.status {
    case "moved": "已整理"
    case "skipped": "已跳过"
    case "error": "失败"
    default: record.status
    }
  }

  private var qbittorrentText: String {
    if record.qbittorrentTaskDeleted {
      return record.deleteFilesFromQbittorrent ? "已移除下载器任务和原文件" : "已移除下载器任务，保留文件"
    }
    return "未移除下载器任务"
  }

  private var qbittorrentIcon: String {
    record.qbittorrentTaskDeleted ? "checkmark.circle" : "arrow.up.arrow.down.circle"
  }

  private var qbittorrentColor: Color {
    record.qbittorrentTaskDeleted ? .green : .secondary
  }

  private var icon: String {
    switch record.status {
    case "moved": "checkmark.circle.fill"
    case "skipped": "arrow.uturn.forward.circle"
    case "error": "exclamationmark.triangle.fill"
    default: "clock"
    }
  }

  private var color: Color {
    switch record.status {
    case "moved": .green
    case "skipped": .orange
    case "error": .red
    default: .secondary
    }
  }

  private var cleanupText: String {
    let path = record.cleanupPath.map { " · \($0)" } ?? ""
    return "\(record.cleanupMessage ?? "已检查空下载目录")\(path)"
  }

  private var cleanupIcon: String {
    switch record.cleanupStatus {
    case "deleted": "folder.badge.minus"
    case "error": "exclamationmark.triangle"
    default: "folder"
    }
  }

  private var cleanupColor: Color {
    switch record.cleanupStatus {
    case "deleted": .green
    case "error": .red
    default: .secondary
    }
  }
}
