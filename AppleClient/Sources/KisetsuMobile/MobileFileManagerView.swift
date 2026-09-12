import SwiftUI

struct MobileFileManagerView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var model = FileBrowserViewModel()
  @State private var showingUnlockConfirmation = false
  @State private var showingCreateFolder = false
  @State private var folderName = ""
  @State private var showingRename = false
  @State private var renameText = ""
  @State private var deletePreview: FileBrowserDeletePreview?
  @State private var directoryNavigation: MobileDirectoryNavigation?
  @State private var isLoadingLocations = false
  @State private var directoryErrors: [String: String] = [:]

  private var isReadingDirectory: Bool {
    isLoadingLocations || model.isSelectedRootLoading || directoryNavigation != nil
  }

  private var canReadDirectories: Bool {
    MobileDebugConfiguration.usesFixturesAtRuntime || MobileDebugConfiguration.shouldLoadNetworkAtRuntime
  }

  private var directoryClient: APIClient {
#if DEBUG
    if MobileDebugConfiguration.usesFixturesAtRuntime {
      return MobileFileBrowserFixture.makeClient(latency: .milliseconds(600))
    }
#endif
    return store.client
  }

  var body: some View {
    List {
      Section {
        Menu {
          ForEach(model.roots) { root in
            Button {
              Task { await selectRoot(root.id) }
            } label: {
              Label(root.name, systemImage: FileBrowserPresentation.rootIcon(kind: root.kind))
            }
          }
        } label: {
          LabeledContent("位置") {
            Text(model.selectedRoot?.name ?? "选择位置")
          }
        }
        .disabled(isReadingDirectory)

        HStack {
          Label(model.isReadOnly ? "只读模式" : "编辑模式", systemImage: model.isReadOnly ? "lock" : "lock.open")
          Spacer()
          if model.isUnlocking { ProgressView() }
        }
        .foregroundStyle(model.isReadOnly ? Color.secondary : Color.orange)
      } footer: {
        if model.isReadOnly {
          Text("默认只读，不会修改后端文件。")
        } else if model.errorMessage == nil {
          Text(model.statusMessage)
        }
      }

      if let operation = model.activeOperation {
        Section("文件操作") {
          ProgressView(value: Double(operation.itemsCompleted), total: Double(max(operation.itemsTotal, 1)))
          Text(operation.message).font(.caption).foregroundStyle(.secondary)
          if FileBrowserPresentation.isOperationActive(operation) {
            Button("取消操作", systemImage: "xmark.circle", role: .destructive) {
              Task { await model.cancelActiveOperation(client: store.client) }
            }
          }
        }
      }

      Section {
        if (isLoadingLocations || model.isSelectedRootLoading) && model.currentDirectoryItems.isEmpty {
          ProgressView("正在读取后端目录")
        } else if model.errorMessage != nil && model.currentDirectoryItems.isEmpty {
          ContentUnavailableView("目录读取失败", systemImage: "exclamationmark.triangle")
        } else if model.currentDirectoryItems.isEmpty {
          ContentUnavailableView("目录为空", systemImage: "folder")
        } else {
          ForEach(model.currentDirectoryItems) { item in
            Button {
              if model.isReadOnly {
                guard item.isDirectory, !item.isSymbolicLink else { return }
                Task { await navigate(to: item.path) }
              } else {
                toggleSelection(item)
              }
            } label: {
              MobileFileRow(item: item, selected: model.selection.contains(item.id))
            }
            .buttonStyle(.plain)
            .disabled(isReadingDirectory)
            .contextMenu {
              if !model.isReadOnly {
                Button("复制", systemImage: "doc.on.doc") { select(item); model.copySelection() }
                Button("剪切", systemImage: "scissors") { select(item); model.cutSelection() }
                Button("重命名", systemImage: "pencil") { beginRename(item) }
                Button("永久删除", systemImage: "trash", role: .destructive) { prepareDelete(item) }
              }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              if !model.isReadOnly {
                Button("重命名", systemImage: "pencil") { beginRename(item) }.tint(.blue)
                Button("删除", systemImage: "trash", role: .destructive) { prepareDelete(item) }
              }
            }
          }
          if let root = model.selectedRoot,
             MobileDirectoryPresentation.hasMore(rootID: root.id, path: model.currentDirectoryPath, cache: model.directoryCache) {
            Button {
              Task { await loadMore() }
            } label: {
              HStack {
                Group {
                  if model.isSelectedRootLoading { ProgressView().controlSize(.small) }
                  else { Image(systemName: "arrow.down.circle") }
                }
                .frame(width: 20, height: 20)
                Text("加载更多")
              }
            }
            .disabled(isReadingDirectory)
          }
        }
      } header: {
        HStack(spacing: 8) {
          Text(model.currentDirectoryPath.isEmpty ? "目录" : model.currentDirectoryPath)
            .lineLimit(2)
          Spacer()
          if model.canGoBack {
            Button("上一级目录", systemImage: "arrow.up.to.line") { Task { await goBack() } }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
              .disabled(isReadingDirectory)
              .accessibilityHint("打开当前目录的父目录")
          }
        }
      }

      if let error = model.errorMessage {
        Section {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
    }
    .overlay {
      ZStack {
        if let directoryNavigation {
          ProgressView(directoryNavigation.title)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .transition(.opacity)
            .accessibilityAddTraits(.updatesFrequently)
        }
      }
      .animation(
        reduceMotion ? MobileMotion.reducedFade : MobileMotion.directory,
        value: directoryNavigation != nil
      )
    }
    .mobileStatusNavigationTitle("文件管理")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        if !model.isReadOnly {
          Menu("文件操作", systemImage: "ellipsis.circle") {
            Button("新建文件夹", systemImage: "folder.badge.plus") {
              folderName = ""
              showingCreateFolder = true
            }
            Button("粘贴", systemImage: "doc.on.clipboard") { Task { await model.paste(client: store.client) } }
              .disabled(!model.canPaste)
            Button("恢复只读", systemImage: "lock") { Task { await model.lock(client: store.client) } }
          }
        } else {
          Button("进入编辑模式", systemImage: "lock.open") { showingUnlockConfirmation = true }
            .disabled(isReadingDirectory || !MobileDebugConfiguration.shouldLoadNetworkAtRuntime)
        }
        MobileToolbarRefreshButton(target: .files, isRefreshing: isReadingDirectory) {
          await refreshDirectory()
        }
      }
    }
    .task {
      await loadLocations()
    }
    .onDisappear { Task { await model.lock(client: store.client) } }
    .alert("进入编辑模式？", isPresented: $showingUnlockConfirmation) {
      Button("进入") { Task { await model.beginEditing(client: store.client) } }
      Button("取消", role: .cancel) {}
    } message: {
      Text("编辑操作会直接作用于后端服务器文件。删除不可恢复，执行前仍会显示核对信息。")
    }
    .alert("新建文件夹", isPresented: $showingCreateFolder) {
      TextField("文件夹名称", text: $folderName)
      Button("创建") { Task { _ = await model.createFolder(named: folderName, client: store.client) } }
      Button("取消", role: .cancel) {}
    }
    .alert("重命名", isPresented: $showingRename) {
      TextField("新名称", text: $renameText)
      Button("保存") { Task { _ = await model.renameSelected(to: renameText, client: store.client) } }
      Button("取消", role: .cancel) {}
    }
    .alert(item: $deletePreview) { preview in
      Alert(
        title: Text("永久删除 \(preview.itemsTotal) 个项目？"),
        message: Text("共 \(preview.filesTotal) 个文件、\(preview.directoriesTotal) 个目录，\(ByteCountFormatter.string(fromByteCount: preview.bytesTotal, countStyle: .binary))。\n\(preview.itemNames.prefix(4).joined(separator: "\n"))"),
        primaryButton: .destructive(Text("永久删除")) {
          Task { await model.delete(preview, client: store.client) }
        },
        secondaryButton: .cancel { model.cancelDeletePreview() }
      )
    }
  }

  private func toggleSelection(_ item: FileBrowserItem) {
    if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
  }

  private func loadLocations() async {
    guard canReadDirectories, !isReadingDirectory else { return }
    isLoadingLocations = true
    defer { isLoadingLocations = false }
    directoryErrors.removeAll()
    model.errorMessage = nil
    await model.load(client: directoryClient)
    rememberDirectoryError()
  }

  private func refreshDirectory() async {
    guard canReadDirectories, !isReadingDirectory else { return }
    model.errorMessage = nil
    directoryErrors.removeAll()
    if model.selectedRoot == nil {
      await loadLocations()
    } else {
      await model.reload(client: directoryClient)
      rememberDirectoryError()
    }
  }

  private func selectRoot(_ rootID: String) async {
    guard canReadDirectories, !isReadingDirectory else { return }
    restoreDirectoryError(rootID: rootID, path: "")
    directoryNavigation = .root
    defer { directoryNavigation = nil }
    await model.selectRoot(rootID, client: directoryClient)
    rememberDirectoryError()
  }

  private func navigate(to path: String) async {
    guard canReadDirectories, !isReadingDirectory else { return }
    restoreDirectoryError(rootID: model.selectedRootID, path: path)
    directoryNavigation = .forward
    defer { directoryNavigation = nil }
    await model.navigate(to: path, client: directoryClient)
    rememberDirectoryError()
  }

  private func goBack() async {
    guard canReadDirectories, !isReadingDirectory else { return }
    let parent = model.currentDirectoryPath.split(separator: "/").dropLast().joined(separator: "/")
    restoreDirectoryError(rootID: model.selectedRootID, path: parent)
    directoryNavigation = .back
    defer { directoryNavigation = nil }
    await model.goBack(client: directoryClient)
    rememberDirectoryError()
  }

  private func loadMore() async {
    guard canReadDirectories, !isReadingDirectory, let root = model.selectedRoot else { return }
    model.errorMessage = nil
    await model.loadMore(rootID: root.id, path: model.currentDirectoryPath, client: directoryClient)
    rememberDirectoryError()
  }

  private func restoreDirectoryError(rootID: String?, path: String) {
    guard let rootID else { model.errorMessage = nil; return }
    let key = FileBrowserPresentation.directoryKey(rootID: rootID, path: path)
    // The shared cache also stores failed reads as empty directories.
    model.errorMessage = model.directoryCache[key] == nil ? nil : directoryErrors[key]
  }

  private func rememberDirectoryError() {
    guard let rootID = model.selectedRootID else { return }
    let key = FileBrowserPresentation.directoryKey(rootID: rootID, path: model.currentDirectoryPath)
    directoryErrors[key] = model.errorMessage
  }

  private func select(_ item: FileBrowserItem) {
    model.selection = [item.id]
  }

  private func beginRename(_ item: FileBrowserItem) {
    select(item)
    renameText = item.name
    showingRename = true
  }

  private func prepareDelete(_ item: FileBrowserItem) {
    select(item)
    Task { deletePreview = await model.prepareDelete(client: store.client) }
  }
}

enum MobileDirectoryPresentation {
  static func hasMore(rootID: String, path: String, cache: [String: FileBrowserDirectoryCache]) -> Bool {
    cache[FileBrowserPresentation.directoryKey(rootID: rootID, path: path)]?.hasMore == true
  }
}

private enum MobileDirectoryNavigation {
  case root
  case forward
  case back

  var title: String {
    switch self {
    case .root: "正在切换位置"
    case .forward: "正在打开目录"
    case .back: "正在返回上一级"
    }
  }
}

private struct MobileFileRow: View {
  var item: FileBrowserItem
  var selected: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: FileBrowserPresentation.itemIcon(item))
        .foregroundStyle(item.isDirectory ? .secondary : .secondary)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text(item.name).foregroundStyle(.primary).lineLimit(2)
        HStack(spacing: 8) {
          if let size = item.sizeBytes {
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .binary))
          }
          if let modified = item.modifiedAt { Text(MobileFormat.date(modified)) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
      else if item.isDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}
