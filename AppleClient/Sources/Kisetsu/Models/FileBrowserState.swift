import Foundation

enum FileBrowserClipboardMode: String, Hashable {
  case copy
  case move

  var title: String {
    switch self {
    case .copy: "复制"
    case .move: "移动"
    }
  }
}

struct FileBrowserClipboard: Hashable {
  var mode: FileBrowserClipboardMode
  var items: [FileBrowserItem]

  var summary: String {
    if items.count == 1, let item = items.first {
      return "\(mode.title)“\(item.name)”"
    }
    return "\(mode.title) \(items.count) 个项目"
  }
}

struct FileBrowserPasteDestination: Hashable {
  var rootID: String
  var path: String
  var title: String
}

struct FileBrowserDirectoryCache: Hashable {
  var items: [FileBrowserItem]
  var total: Int
  var hasMore: Bool
}

struct FileBrowserTreeNode: Hashable, Identifiable {
  var item: FileBrowserItem
  var children: [FileBrowserTreeNode]?

  var id: String { item.id }
}

struct FileBrowserBreadcrumb: Hashable, Identifiable {
  var path: String
  var title: String

  var id: String { path }
}

enum FileBrowserPresentation {
  static func rootIcon(kind: String) -> String {
    switch kind {
    case "download": "arrow.down.circle"
    case "brush": "arrow.up.arrow.down.circle"
    case "library": "play.rectangle.on.rectangle"
    default: "clock.arrow.circlepath"
    }
  }

  static func itemIcon(_ item: FileBrowserItem) -> String {
    if item.isSymbolicLink { return "link" }
    return switch item.kind {
    case "directory": "folder"
    case "video": "film"
    case "audio": "waveform"
    case "subtitle": "captions.bubble"
    case "image": "photo"
    case "archive": "archivebox"
    default: "doc"
    }
  }

  static func directoryKey(rootID: String, path: String) -> String {
    "\(rootID)\u{1F}\(path)"
  }

  static func parentName(path: String, rootName: String) -> String {
    guard !path.isEmpty else { return rootName }
    return path.split(separator: "/").last.map(String.init) ?? rootName
  }

  static func isOperationActive(_ operation: FileBrowserOperationStatus?) -> Bool {
    guard let operation else { return false }
    return operation.status == "queued" || operation.status == "running"
  }

  static func placeholder(rootID: String, path: String, kind: String) -> FileBrowserItem {
    FileBrowserItem(
      id: "placeholder:\(kind):\(directoryKey(rootID: rootID, path: path))",
      rootId: rootID,
      path: path,
      parentPath: path,
      name: kind == "load_more" ? "加载更多" : "正在读取…",
      kind: kind,
      isDirectory: false,
      isSymbolicLink: false,
      isHidden: false,
      isExpandable: false,
      sizeBytes: nil,
      modifiedAt: nil
    )
  }
}

@MainActor
final class FileBrowserViewModel: ObservableObject {
  @Published private(set) var roots: [FileBrowserRoot] = []
  @Published var selectedRootID: String?
  @Published var selection: Set<String> = []
  @Published private(set) var currentDirectoryPath = ""
  @Published private(set) var directoryCache: [String: FileBrowserDirectoryCache] = [:]
  @Published private(set) var loadingDirectoryKeys: Set<String> = []
  @Published private(set) var clipboard: FileBrowserClipboard?
  @Published private(set) var isReadOnly = true
  @Published private(set) var isUnlocking = false
  @Published private(set) var isPreparingDelete = false
  @Published var showHidden = false
  @Published private(set) var statusMessage = "默认只读，不会修改后端文件。"
  @Published var errorMessage: String?
  @Published private(set) var activeOperation: FileBrowserOperationStatus?

  private var editToken: String?
  private var operationPollingTask: Task<Void, Never>?
  private var itemIndex: [String: FileBrowserItem] = [:]

  var selectedRoot: FileBrowserRoot? {
    guard let selectedRootID else { return nil }
    return roots.first { $0.id == selectedRootID }
  }

  var currentDirectoryItems: [FileBrowserItem] {
    guard let root = selectedRoot else { return [] }
    return directoryCache[
      FileBrowserPresentation.directoryKey(rootID: root.id, path: currentDirectoryPath)
    ]?.items ?? []
  }

  var isSelectedRootLoading: Bool {
    guard let root = selectedRoot else { return false }
    return loadingDirectoryKeys.contains(
      FileBrowserPresentation.directoryKey(rootID: root.id, path: currentDirectoryPath)
    )
  }

  var treeNodes: [FileBrowserTreeNode] {
    buildTree(currentDirectoryItems)
  }

  var canGoBack: Bool {
    !currentDirectoryPath.isEmpty
  }

  var breadcrumbs: [FileBrowserBreadcrumb] {
    guard let root = selectedRoot else { return [] }
    var result = [FileBrowserBreadcrumb(path: "", title: root.name)]
    var path = ""
    for component in currentDirectoryPath.split(separator: "/") {
      path = path.isEmpty ? String(component) : "\(path)/\(component)"
      result.append(FileBrowserBreadcrumb(path: path, title: String(component)))
    }
    return result
  }

  var selectedItems: [FileBrowserItem] {
    selection.compactMap { itemIndex[$0] }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  var canCopy: Bool {
    !isReadOnly && !selectedItems.isEmpty && selectedItems.allSatisfy { !$0.isSymbolicLink }
      && !FileBrowserPresentation.isOperationActive(activeOperation)
  }

  var canCut: Bool {
    !isReadOnly && canCopy && selectedItems.allSatisfy { root(for: $0.rootId)?.writable == true }
  }

  var canRename: Bool {
    guard !isReadOnly,
          selectedItems.count == 1,
          let item = selectedItems.first,
          !item.isSymbolicLink else { return false }
    return root(for: item.rootId)?.writable == true
      && !FileBrowserPresentation.isOperationActive(activeOperation)
  }

  var canCreateFolder: Bool {
    !isReadOnly && pasteDestination != nil && pasteDestinationRoot?.writable == true
      && !FileBrowserPresentation.isOperationActive(activeOperation)
  }

  var canPaste: Bool {
    !isReadOnly && clipboard != nil && pasteDestination != nil && pasteDestinationRoot?.writable == true
      && !FileBrowserPresentation.isOperationActive(activeOperation)
  }

  var canDelete: Bool {
    !isReadOnly && !isPreparingDelete && !selectedItems.isEmpty
      && selectedItems.allSatisfy { item in
        !item.isSymbolicLink && root(for: item.rootId)?.writable == true
      }
      && !FileBrowserPresentation.isOperationActive(activeOperation)
  }

  var pasteDestination: FileBrowserPasteDestination? {
    guard let root = selectedRoot else { return nil }
    let items = selectedItems
    if items.count == 1, let item = items.first {
      let path = item.isDirectory && !item.isSymbolicLink ? item.path : item.parentPath
      return FileBrowserPasteDestination(
        rootID: item.rootId,
        path: path,
        title: FileBrowserPresentation.parentName(path: path, rootName: root.name)
      )
    }
    if !items.isEmpty,
       let first = items.first,
       items.allSatisfy({ $0.rootId == first.rootId && $0.parentPath == first.parentPath }) {
      return FileBrowserPasteDestination(
        rootID: first.rootId,
        path: first.parentPath,
        title: FileBrowserPresentation.parentName(path: first.parentPath, rootName: root.name)
      )
    }
    return FileBrowserPasteDestination(
      rootID: root.id,
      path: currentDirectoryPath,
      title: FileBrowserPresentation.parentName(path: currentDirectoryPath, rootName: root.name)
    )
  }

  var pasteDestinationRoot: FileBrowserRoot? {
    pasteDestination.flatMap { root(for: $0.rootID) }
  }

  var clipboardSummary: String? {
    clipboard?.summary
  }

  func load(client: APIClient) async {
    errorMessage = nil
    do {
      async let rootResponse = client.fileBrowserRoots()
      async let operations = client.recentFileBrowserOperations(limit: 20)
      let response = try await rootResponse
      roots = response.roots
      statusMessage = response.message
      if let selectedRootID, roots.contains(where: { $0.id == selectedRootID }) {
        self.selectedRootID = selectedRootID
      } else {
        selectedRootID = roots.first(where: { $0.readable })?.id ?? roots.first?.id
      }
      currentDirectoryPath = ""
      clearTree()
      if let selectedRootID {
        await loadDirectory(rootID: selectedRootID, path: "", client: client)
      }
      let recentOperations = (try? await operations) ?? []
      if let running = recentOperations.first(where: FileBrowserPresentation.isOperationActive) {
        activeOperation = running
        beginPolling(operationID: running.id, client: client)
      }
    } catch {
      handle(error)
    }
  }

  func selectRoot(_ rootID: String?, client: APIClient) async {
    selectedRootID = rootID
    currentDirectoryPath = ""
    selection.removeAll()
    guard let rootID else { return }
    let key = FileBrowserPresentation.directoryKey(rootID: rootID, path: "")
    if directoryCache[key] == nil {
      await loadDirectory(rootID: rootID, path: "", client: client)
    }
  }

  func ensureDirectoryLoaded(rootID: String, path: String, client: APIClient) async {
    let key = FileBrowserPresentation.directoryKey(rootID: rootID, path: path)
    if directoryCache[key] == nil {
      await loadDirectory(rootID: rootID, path: path, client: client)
    }
  }

  func directoryHasMore(_ item: FileBrowserItem?) -> Bool {
    guard let root = selectedRoot else { return false }
    let key: String
    if let item {
      key = FileBrowserPresentation.directoryKey(rootID: item.rootId, path: item.path)
    } else {
      key = FileBrowserPresentation.directoryKey(rootID: root.id, path: "")
    }
    return directoryCache[key]?.hasMore == true
  }

  func loadMore(in item: FileBrowserItem?, client: APIClient) async {
    guard let root = selectedRoot else { return }
    let rootID = item?.rootId ?? root.id
    let path = item?.path ?? currentDirectoryPath
    let key = FileBrowserPresentation.directoryKey(rootID: rootID, path: path)
    guard let cache = directoryCache[key], cache.hasMore else { return }
    await loadDirectory(rootID: rootID, path: path, offset: cache.items.count, append: true, client: client)
  }

  func loadMore(rootID: String, path: String, client: APIClient) async {
    let key = FileBrowserPresentation.directoryKey(rootID: rootID, path: path)
    guard let cache = directoryCache[key], cache.hasMore else { return }
    await loadDirectory(rootID: rootID, path: path, offset: cache.items.count, append: true, client: client)
  }

  func reload(client: APIClient) async {
    let rootID = selectedRootID
    let path = currentDirectoryPath
    clearTree()
    if let rootID {
      await loadDirectory(rootID: rootID, path: path, client: client)
    }
  }

  func openPrimarySelection(_ ids: Set<String>, client: APIClient) async {
    guard ids.count == 1,
          let id = ids.first,
          let item = itemIndex[id],
          item.isDirectory,
          !item.isSymbolicLink,
          item.rootId == selectedRootID else { return }
    await navigate(to: item.path, client: client)
  }

  func navigate(to path: String, client: APIClient) async {
    guard let rootID = selectedRootID else { return }
    currentDirectoryPath = path
    selection.removeAll()
    await ensureDirectoryLoaded(rootID: rootID, path: path, client: client)
  }

  func goBack(client: APIClient) async {
    guard canGoBack else { return }
    let parent = currentDirectoryPath.split(separator: "/").dropLast().joined(separator: "/")
    await navigate(to: parent, client: client)
  }

  func updateHiddenItems(client: APIClient) async {
    await reload(client: client)
  }

  func beginEditing(client: APIClient) async {
    guard isReadOnly, !isUnlocking else { return }
    isUnlocking = true
    errorMessage = nil
    defer { isUnlocking = false }
    do {
      let session = try await client.beginFileBrowserEditSession()
      editToken = session.token
      isReadOnly = false
      statusMessage = session.message
    } catch {
      handle(error)
    }
  }

  func lock(client: APIClient) async {
    let token = editToken
    editToken = nil
    isReadOnly = true
    clipboard = nil
    statusMessage = FileBrowserPresentation.isOperationActive(activeOperation)
      ? "已恢复只读；当前文件操作会在后端继续完成。"
      : "已恢复只读模式。"
    guard let token else { return }
    _ = try? await client.lockFileBrowserEditSession(token: token)
  }

  func copySelection() {
    guard canCopy else { return }
    clipboard = FileBrowserClipboard(mode: .copy, items: selectedItems)
    statusMessage = "已复制到文件管理剪贴板。"
  }

  func cutSelection() {
    guard canCut else { return }
    clipboard = FileBrowserClipboard(mode: .move, items: selectedItems)
    statusMessage = "已剪切；选择目标文件夹后粘贴即可移动。"
  }

  func renameSelected(to newName: String, client: APIClient) async -> Bool {
    guard canRename, let item = selectedItems.first, let token = editToken else { return false }
    do {
      let response = try await client.renameFileBrowserItem(
        FileBrowserRenameRequest(editToken: token, rootId: item.rootId, path: item.path, newName: newName)
      )
      statusMessage = response.message
      selection.removeAll()
      await reload(client: client)
      return true
    } catch {
      handle(error)
      return false
    }
  }

  func createFolder(named name: String, client: APIClient) async -> Bool {
    guard canCreateFolder, let destination = pasteDestination, let token = editToken else { return false }
    do {
      let response = try await client.createFileBrowserFolder(
        FileBrowserCreateFolderRequest(
          editToken: token,
          rootId: destination.rootID,
          parentPath: destination.path,
          name: name
        )
      )
      statusMessage = response.message
      await reload(client: client)
      return true
    } catch {
      handle(error)
      return false
    }
  }

  func prepareDelete(client: APIClient) async -> FileBrowserDeletePreview? {
    guard canDelete, let token = editToken else { return nil }
    let items = selectedItems
    let selectedIDs = Set(items.map(\.id))
    isPreparingDelete = true
    errorMessage = nil
    statusMessage = "正在核对待删除内容…"
    defer { isPreparingDelete = false }
    do {
      let preview = try await client.previewFileBrowserDelete(
        FileBrowserDeletePreviewRequest(
          editToken: token,
          sources: items.map { FileBrowserReference(rootId: $0.rootId, path: $0.path) }
        )
      )
      guard !isReadOnly, selection == selectedIDs else {
        statusMessage = "选择或编辑状态已变化，请重新选择后再删除。"
        return nil
      }
      statusMessage = preview.message
      return preview
    } catch {
      handle(error)
      return nil
    }
  }

  func delete(_ preview: FileBrowserDeletePreview, client: APIClient) async {
    guard !isReadOnly,
          !FileBrowserPresentation.isOperationActive(activeOperation),
          let token = editToken else { return }
    do {
      let operation = try await client.startFileBrowserDelete(
        FileBrowserDeleteRequest(editToken: token, previewToken: preview.token)
      )
      selection.removeAll()
      clipboard = nil
      activeOperation = operation
      statusMessage = operation.message
      beginPolling(operationID: operation.id, client: client)
    } catch {
      handle(error)
      await reload(client: client)
    }
  }

  func cancelDeletePreview() {
    statusMessage = "已取消永久删除。"
  }

  func paste(client: APIClient) async {
    guard canPaste,
          let clipboard,
          let destination = pasteDestination,
          let token = editToken else { return }
    do {
      let operation = try await client.startFileBrowserOperation(
        FileBrowserOperationRequest(
          editToken: token,
          kind: clipboard.mode.rawValue,
          sources: clipboard.items.map { FileBrowserReference(rootId: $0.rootId, path: $0.path) },
          destinationRootId: destination.rootID,
          destinationPath: destination.path
        )
      )
      activeOperation = operation
      statusMessage = operation.message
      beginPolling(operationID: operation.id, client: client)
    } catch {
      handle(error)
    }
  }

  func cancelActiveOperation(client: APIClient) async {
    guard let operation = activeOperation, let token = editToken else { return }
    do {
      activeOperation = try await client.cancelFileBrowserOperation(id: operation.id, token: token)
      statusMessage = activeOperation?.message ?? "正在取消…"
    } catch {
      handle(error)
    }
  }

  func dismissOperation() {
    guard !FileBrowserPresentation.isOperationActive(activeOperation) else { return }
    activeOperation = nil
  }

  func root(for id: String) -> FileBrowserRoot? {
    roots.first { $0.id == id }
  }

  private func loadDirectory(
    rootID: String,
    path: String,
    offset: Int = 0,
    append: Bool = false,
    client: APIClient
  ) async {
    let key = FileBrowserPresentation.directoryKey(rootID: rootID, path: path)
    guard !loadingDirectoryKeys.contains(key) else { return }
    loadingDirectoryKeys.insert(key)
    defer { loadingDirectoryKeys.remove(key) }
    do {
      let page = try await client.fileBrowserDirectory(
        rootID: rootID,
        path: path,
        offset: offset,
        limit: 500,
        showHidden: showHidden
      )
      let previous = append ? directoryCache[key]?.items ?? [] : []
      let items = previous + page.items.filter { newItem in !previous.contains(where: { $0.id == newItem.id }) }
      directoryCache[key] = FileBrowserDirectoryCache(items: items, total: page.total, hasMore: page.hasMore)
      for item in items {
        itemIndex[item.id] = item
      }
    } catch {
      handle(error)
      directoryCache[key] = FileBrowserDirectoryCache(items: [], total: 0, hasMore: false)
    }
  }

  private func clearTree() {
    selection.removeAll()
    directoryCache.removeAll()
    itemIndex.removeAll()
  }

  private func buildTree(_ items: [FileBrowserItem]) -> [FileBrowserTreeNode] {
    items.map { item in
      guard item.isExpandable else {
        return FileBrowserTreeNode(item: item, children: nil)
      }
      let key = FileBrowserPresentation.directoryKey(rootID: item.rootId, path: item.path)
      if let cache = directoryCache[key] {
        var children = buildTree(cache.items)
        if cache.hasMore {
          children.append(
            FileBrowserTreeNode(
              item: FileBrowserPresentation.placeholder(rootID: item.rootId, path: item.path, kind: "load_more"),
              children: nil
            )
          )
        }
        return FileBrowserTreeNode(item: item, children: children)
      }
      return FileBrowserTreeNode(
        item: item,
        children: [
          FileBrowserTreeNode(
            item: FileBrowserPresentation.placeholder(rootID: item.rootId, path: item.path, kind: "loading"),
            children: nil
          )
        ]
      )
    }
  }

  private func beginPolling(operationID: String, client: APIClient) {
    operationPollingTask?.cancel()
    operationPollingTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .milliseconds(350))
          guard let self else { return }
          let operation = try await client.fileBrowserOperation(id: operationID)
          self.activeOperation = operation
          self.statusMessage = operation.message
          guard FileBrowserPresentation.isOperationActive(operation) else {
            if operation.status == "success" || operation.status == "partial" || operation.kind == "delete" {
              if self.clipboard?.mode == .move {
                self.clipboard = nil
              }
              await self.reload(client: client)
            }
            return
          }
        } catch is CancellationError {
          return
        } catch {
          guard let self else { return }
          self.handle(error)
          return
        }
      }
    }
  }

  private func handle(_ error: Error) {
    let message = error.localizedDescription
    errorMessage = message
    statusMessage = message
    if message.contains("只读模式") || message.contains("编辑会话") {
      editToken = nil
      isReadOnly = true
      clipboard = nil
    }
  }
}
