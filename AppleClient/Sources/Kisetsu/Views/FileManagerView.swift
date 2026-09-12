import AppKit
import SwiftUI

struct FileManagerView: View {
  @EnvironmentObject private var store: AppStore
  @StateObject private var model = FileBrowserViewModel()
  @StateObject private var keyboardMonitor = FileBrowserKeyboardMonitor()
  @State private var showingEditConfirmation = false
  @State private var showingMoveConfirmation = false
  @State private var showingRenamePrompt = false
  @State private var showingFolderPrompt = false
  @State private var deletePreview: FileBrowserDeletePreview?
  @State private var renameText = ""
  @State private var folderName = ""

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      HSplitView {
        rootList
          .frame(minWidth: 190, idealWidth: 230, maxWidth: 280)
        browser
          .frame(minWidth: 560)
      }
      statusBar
    }
    .task(id: store.backendURL) {
      await model.load(client: store.client)
    }
    .onAppear {
      keyboardMonitor.start()
    }
    .onDisappear {
      keyboardMonitor.stop()
      Task { await model.lock(client: store.client) }
    }
    .alert("关闭只读模式？", isPresented: $showingEditConfirmation) {
      Button("取消", role: .cancel) {}
      Button("开启编辑模式") {
        Task { await model.beginEditing(client: store.client) }
      }
    } message: {
      Text("编辑模式会修改后端电脑上的真实文件。重命名、移动或永久删除下载中的内容可能影响下载器任务；永久删除不会移到废纸篓，且无法撤销。离开此页面后会自动恢复只读。")
    }
    .alert("重命名", isPresented: $showingRenamePrompt) {
      TextField("新名称", text: $renameText)
      Button("取消", role: .cancel) {}
      Button("重命名") {
        let name = renameText
        Task { _ = await model.renameSelected(to: name, client: store.client) }
      }
      .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: {
      Text("输入新名称，不会覆盖同名项目。")
    }
    .alert("新建文件夹", isPresented: $showingFolderPrompt) {
      TextField("文件夹名称", text: $folderName)
      Button("取消", role: .cancel) {}
      Button("创建") {
        let name = folderName
        Task { _ = await model.createFolder(named: name, client: store.client) }
      }
      .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: {
      Text("将在“\(model.pasteDestination?.title ?? "当前目录")”中创建，不会覆盖现有项目。")
    }
    .alert("移动所选项目？", isPresented: $showingMoveConfirmation) {
      Button("取消", role: .cancel) {}
      Button("移动") {
        Task { await model.paste(client: store.client) }
      }
    } message: {
      Text("项目将移动到“\(model.pasteDestination?.title ?? "当前目录")”。移动下载中的文件可能影响下载器任务。")
    }
    .alert(item: $deletePreview) { preview in
      Alert(
        title: Text("永久删除所选项目？"),
        message: Text(deleteConfirmationMessage(preview)),
        primaryButton: .destructive(Text("永久删除")) {
          Task { await model.delete(preview, client: store.client) }
        },
        secondaryButton: .cancel(Text("取消")) {
          model.cancelDeletePreview()
        }
      )
    }
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      Button {
        Task { await model.reload(client: store.client) }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .help("刷新当前目录")

      Divider()
        .frame(height: 18)

      Button {
        folderName = ""
        showingFolderPrompt = true
      } label: {
        Image(systemName: "folder.badge.plus")
      }
      .help("新建文件夹")
      .disabled(!model.canCreateFolder)

      Button {
        model.copySelection()
      } label: {
        Image(systemName: "square.on.square")
      }
      .help("复制")
      .disabled(!model.canCopy)

      Button {
        model.cutSelection()
      } label: {
        Image(systemName: "scissors")
      }
      .help("剪切以移动")
      .disabled(!model.canCut)

      Button {
        paste()
      } label: {
        Image(systemName: "doc.on.clipboard")
      }
      .help(pasteHelp)
      .disabled(!model.canPaste)

      Button {
        prepareRename()
      } label: {
        Image(systemName: "pencil")
      }
      .help("重命名")
      .disabled(!model.canRename)

      Divider()
        .frame(height: 18)

      Button(role: .destructive) {
        prepareDelete()
      } label: {
        Group {
          if model.isPreparingDelete {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "trash")
          }
        }
        .frame(width: 16, height: 16)
      }
      .keyboardShortcut(.delete, modifiers: .command)
      .help("永久删除所选项目…")
      .accessibilityLabel("永久删除所选项目")
      .disabled(!model.canDelete)

      Menu {
        Toggle("显示隐藏项目", isOn: Binding(
          get: { model.showHidden },
          set: { newValue in
            model.showHidden = newValue
            Task { await model.updateHiddenItems(client: store.client) }
          }
        ))
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("更多显示选项")

      Spacer(minLength: 16)

      if model.isUnlocking {
        ProgressView()
          .controlSize(.small)
          .help("正在开启编辑模式")
      }

      Toggle("只读模式", isOn: readOnlyBinding)
        .toggleStyle(.switch)
        .disabled(model.isUnlocking)
        .help(model.isReadOnly ? "关闭后才能修改后端文件" : "开启后立即锁定文件操作")
    }
    .appToolbarSurface()
  }

  private var rootList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 6) {
        Text("位置")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.top, 4)

        ForEach(model.roots) { root in
          FileManagerLocationRow(
            root: root,
            isSelected: model.selectedRootID == root.id
          ) {
            Task { await model.selectRoot(root.id, client: store.client) }
          }
          .help(locationHelp(root))
        }
      }
      .padding(10)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private var browser: some View {
    if model.roots.isEmpty {
      ContentUnavailableView(
        "没有可管理的目录",
        systemImage: "folder.badge.questionmark",
        description: Text("请先配置下载器保存路径、刷流路径或媒体整理目录。")
      )
    } else if let root = model.selectedRoot, !root.readable {
      ContentUnavailableView(
        "无法读取此位置",
        systemImage: "externaldrive.badge.exclamationmark",
        description: Text("请确认后端电脑上的目录存在且具有读取权限。")
      )
    } else {
      VStack(spacing: 0) {
        directoryNavigationBar
        Divider()

        ZStack {
          Table(model.treeNodes, children: \.children, selection: $model.selection) {
            TableColumn("名称") { node in
              itemName(node.item)
            }
            .width(min: 260, ideal: 460)

            TableColumn("大小") { node in
              Text(sizeText(node.item))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .width(min: 80, ideal: 100, max: 130)

            TableColumn("修改日期") { node in
              Text(dateText(node.item.modifiedAt))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .width(min: 120, ideal: 150, max: 180)
          }
          .contextMenu(forSelectionType: String.self) { _ in
            fileActions
          } primaryAction: { ids in
            Task { await model.openPrimarySelection(ids, client: store.client) }
          }

          if model.isSelectedRootLoading {
            ProgressView("正在读取目录…")
              .controlSize(.small)
              .allowsHitTesting(false)
          } else if model.currentDirectoryItems.isEmpty, let root = model.selectedRoot, root.readable {
            ContentUnavailableView("文件夹为空", systemImage: "folder", description: Text("此位置暂无可显示的项目。"))
              .allowsHitTesting(false)
          }
        }
      }
    }
  }

  private var directoryNavigationBar: some View {
    HStack(spacing: 6) {
      Button {
        Task { await model.goBack(client: store.client) }
      } label: {
        Image(systemName: "chevron.left")
      }
      .buttonStyle(.borderless)
      .disabled(!model.canGoBack)
      .help("返回上一级")

      Divider()
        .frame(height: 16)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { index, breadcrumb in
            if index > 0 {
              Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Button {
              Task { await model.navigate(to: breadcrumb.path, client: store.client) }
            } label: {
              Text(breadcrumb.title)
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
              breadcrumb.path == model.currentDirectoryPath ? Color.primary : Color.secondary
            )
            .disabled(breadcrumb.path == model.currentDirectoryPath)
          }
        }
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 10)
    .frame(height: 34)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private func itemName(_ item: FileBrowserItem) -> some View {
    switch item.kind {
    case "loading":
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("正在读取…")
          .foregroundStyle(.secondary)
      }
      .task {
        await model.ensureDirectoryLoaded(rootID: item.rootId, path: item.path, client: store.client)
      }
    case "load_more":
      Button {
        Task { await model.loadMore(rootID: item.rootId, path: item.path, client: store.client) }
      } label: {
        Label("加载更多", systemImage: "ellipsis")
      }
      .buttonStyle(.plain)
      .foregroundStyle(Color.accentColor)
    default:
      HStack(spacing: 8) {
        Image(systemName: FileBrowserPresentation.itemIcon(item))
          .foregroundStyle(item.isSymbolicLink ? Color.secondary : item.isDirectory ? Color.accentColor : Color.secondary)
          .frame(width: 18)
        Text(item.name)
          .lineLimit(1)
          .help(item.name)
        if item.isSymbolicLink {
          Image(systemName: "lock.fill")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .help("符号链接仅可查看，不会跟随或编辑")
        }
      }
    }
  }

  @ViewBuilder
  private var fileActions: some View {
    Button("复制", systemImage: "square.on.square") {
      model.copySelection()
    }
    .disabled(!model.canCopy)

    Button("剪切", systemImage: "scissors") {
      model.cutSelection()
    }
    .disabled(!model.canCut)

    Button("粘贴", systemImage: "doc.on.clipboard") {
      paste()
    }
    .disabled(!model.canPaste)

    Divider()

    Button("重命名", systemImage: "pencil") {
      prepareRename()
    }
    .disabled(!model.canRename)

    Button("新建文件夹", systemImage: "folder.badge.plus") {
      folderName = ""
      showingFolderPrompt = true
    }
    .disabled(!model.canCreateFolder)

    Divider()

    Button("永久删除…", systemImage: "trash", role: .destructive) {
      prepareDelete()
    }
    .disabled(!model.canDelete)
  }

  @ViewBuilder
  private var statusBar: some View {
    VStack(spacing: 0) {
      if let error = model.errorMessage {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Text(error)
            .lineLimit(2)
          Spacer()
          Button {
            model.errorMessage = nil
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .help("关闭错误提示")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.06))
        Divider()
      }

      if let operation = model.activeOperation {
        operationStatus(operation)
        Divider()
      }

      HStack(spacing: 8) {
        Image(systemName: model.isReadOnly ? "lock.fill" : "lock.open.fill")
          .foregroundStyle(model.isReadOnly ? Color.secondary : Color.orange)
        Text(model.statusMessage)
          .lineLimit(1)
        if let clipboard = model.clipboardSummary {
          Divider().frame(height: 12)
          Text(clipboard)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        if !model.selection.isEmpty {
          Text("已选择 \(model.selection.count) 项")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)
      .padding(.horizontal, 12)
      .frame(height: 30)
      .background(Color(nsColor: .windowBackgroundColor))
    }
  }

  private func operationStatus(_ operation: FileBrowserOperationStatus) -> some View {
    HStack(spacing: 10) {
      if FileBrowserPresentation.isOperationActive(operation) {
        ProgressView(value: operationProgress(operation))
          .frame(width: 120)
      } else {
        Image(systemName: operation.status == "success" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
          .foregroundStyle(operation.status == "success" ? Color.green : Color.orange)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(operation.message)
          .lineLimit(1)
        Text(operationDetail(operation))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if FileBrowserPresentation.isOperationActive(operation), operation.kind != "delete" {
        Button("取消") {
          Task { await model.cancelActiveOperation(client: store.client) }
        }
        .disabled(model.isReadOnly)
      } else {
        Button {
          model.dismissOperation()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .help("关闭操作状态")
      }
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(Color.accentColor.opacity(0.045))
    .help(operation.errors.joined(separator: "\n"))
  }

  private var readOnlyBinding: Binding<Bool> {
    Binding(
      get: { model.isReadOnly },
      set: { newValue in
        if newValue {
          Task { await model.lock(client: store.client) }
        } else {
          showingEditConfirmation = true
        }
      }
    )
  }

  private var pasteHelp: String {
    guard let destination = model.pasteDestination else { return "粘贴" }
    return "粘贴到“\(destination.title)”"
  }

  private func paste() {
    guard model.canPaste else { return }
    if model.clipboard?.mode == .move {
      showingMoveConfirmation = true
    } else {
      Task { await model.paste(client: store.client) }
    }
  }

  private func prepareRename() {
    guard let item = model.selectedItems.first else { return }
    renameText = item.name
    showingRenamePrompt = true
  }

  private func prepareDelete() {
    guard model.canDelete else { return }
    Task {
      deletePreview = await model.prepareDelete(client: store.client)
    }
  }

  private func deleteConfirmationMessage(_ preview: FileBrowserDeletePreview) -> String {
    let target: String
    if preview.itemsTotal == 1, let name = preview.itemNames.first {
      target = "“\(name)”"
    } else {
      target = "所选 \(preview.itemsTotal) 个项目"
    }
    var summary = "包含 \(preview.filesTotal) 个文件和 \(preview.directoriesTotal) 个文件夹"
    if preview.bytesTotal > 0 {
      summary += "，共 \(ByteCountFormatter.string(fromByteCount: preview.bytesTotal, countStyle: .file))"
    }
    return "\(target)\n\(summary)。文件将从后端电脑永久删除，不会移到废纸篓，且无法撤销。删除下载中或做种中的内容会影响下载器任务。"
  }

  private func locationHelp(_ root: FileBrowserRoot) -> String {
    guard root.exists else { return "位置不存在" }
    guard root.readable else { return "没有读取权限" }
    let sourceSummary = root.sources.count > 1 ? "\(root.sources.count) 个配置共用此目录" : "Kisetsu 管理目录"
    return root.writable ? sourceSummary : "\(sourceSummary)，当前只读"
  }

  private func sizeText(_ item: FileBrowserItem) -> String {
    guard !item.isDirectory, let value = item.sizeBytes else { return "--" }
    return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }

  private func dateText(_ value: String?) -> String {
    guard let value, let date = Self.dateFormatter.date(from: value) else { return "--" }
    return Self.displayDateFormatter.string(from: date)
  }

  private func operationProgress(_ operation: FileBrowserOperationStatus) -> Double {
    if let total = operation.bytesTotal, total > 0 {
      return min(1, Double(operation.bytesCompleted) / Double(total))
    }
    guard operation.itemsTotal > 0 else { return 0 }
    return min(1, Double(operation.itemsCompleted) / Double(operation.itemsTotal))
  }

  private func operationDetail(_ operation: FileBrowserOperationStatus) -> String {
    var parts = ["\(operation.itemsCompleted)/\(operation.itemsTotal) 项"]
    if operation.kind == "delete", FileBrowserPresentation.isOperationActive(operation) {
      parts.append("开始后不能取消")
    }
    if let total = operation.bytesTotal, total > 0 {
      parts.append("\(ByteCountFormatter.string(fromByteCount: operation.bytesCompleted, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
    }
    if let item = operation.currentItem, !item.isEmpty {
      parts.append(item)
    }
    if let error = operation.errors.first, !error.isEmpty {
      parts.append(error)
    }
    return parts.joined(separator: " · ")
  }

  private static let dateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let displayDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()
}

private struct FileManagerLocationRow: View {
  var root: FileBrowserRoot
  var isSelected: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: FileBrowserPresentation.rootIcon(kind: root.kind))
          .frame(width: 18)
        Text(root.name)
          .lineLimit(1)
        Spacer(minLength: 0)
        if !root.exists || !root.readable {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(Color.orange)
            .accessibilityLabel(root.exists ? "没有读取权限" : "位置不存在")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        isSelected ? KisetsuStyle.selectionBackground : Color.clear,
        in: RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
  }
}

@MainActor
enum FileBrowserOutlineCommands {
  static func expandSelection() -> Bool {
    guard let outlineView = focusedOutlineView() else { return false }
    return expandSelection(in: outlineView)
  }

  static func expandSelection(in outlineView: NSOutlineView) -> Bool {
    let items = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) }
    var changed = false
    for item in items where outlineView.isExpandable(item) && !outlineView.isItemExpanded(item) {
      outlineView.expandItem(item)
      changed = true
    }
    return changed
  }

  static func collapseSelection() -> Bool {
    guard let outlineView = focusedOutlineView() else { return false }
    return collapseSelection(in: outlineView)
  }

  static func collapseSelection(in outlineView: NSOutlineView) -> Bool {
    let items = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) }
    var changed = false
    for item in items where outlineView.isItemExpanded(item) {
      outlineView.collapseItem(item)
      changed = true
    }
    return changed
  }

  static func focusedOutlineView() -> NSOutlineView? {
    var responder = NSApp.keyWindow?.firstResponder
    while let current = responder {
      if let outlineView = current as? NSOutlineView {
        return outlineView
      }
      if let view = current as? NSView, let superview = view.superview {
        responder = superview
      } else {
        responder = current.nextResponder
      }
    }
    return nil
  }
}

@MainActor
final class FileBrowserKeyboardMonitor: ObservableObject {
  private var monitor: Any?

  func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard Self.acceptsCommandArrowModifiers(event.modifierFlags),
            FileBrowserOutlineCommands.focusedOutlineView() != nil else {
        return event
      }
      switch event.specialKey {
      case .rightArrow:
        return FileBrowserOutlineCommands.expandSelection() ? nil : event
      case .leftArrow:
        return FileBrowserOutlineCommands.collapseSelection() ? nil : event
      default:
        return event
      }
    }
  }

  func stop() {
    guard let monitor else { return }
    NSEvent.removeMonitor(monitor)
    self.monitor = nil
  }

  static func acceptsCommandArrowModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
    flags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.numericPad, .function]) == .command
  }
}
