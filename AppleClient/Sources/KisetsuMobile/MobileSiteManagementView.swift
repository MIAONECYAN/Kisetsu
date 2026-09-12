import SwiftUI

struct MobileSiteManagementView: View {
  @EnvironmentObject private var store: AppStore
  @State private var isRefreshing = false

  var body: some View {
    List(store.sites) { site in
      NavigationLink {
        MobileSiteEditorView(site: site)
      } label: {
        HStack(spacing: 12) {
          Image(systemName: site.supportsBrush == true ? "arrow.up.arrow.down.circle" : "antenna.radiowaves.left.and.right")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 4) {
            Text(site.label).font(.headline)
            MobileTagFlowLayout {
              MobileTag(text: site.enabled == false ? "已停用" : "已启用", tint: site.enabled == false ? .secondary : .green)
              if site.brushOnly == true { MobileTag(text: "仅刷流") }
              if site.supportsSearch { MobileTag(text: "搜索") }
              if site.supportsRss { MobileTag(text: "RSS") }
            }
          }
        }
      }
    }
    .overlay {
      if store.sites.isEmpty {
        if isRefreshing {
          ProgressView("正在读取站点")
        } else {
          ContentUnavailableView("暂无站点", systemImage: "antenna.radiowaves.left.and.right")
        }
      }
    }
    .mobileStatusNavigationTitle("站点管理")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        MobileToolbarRefreshButton(target: .sites, isRefreshing: isRefreshing) {
          await refresh()
        }
      }
    }
    .refreshable {
      await refresh()
    }
    .task {
      await refresh()
    }
  }

  private func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    #if DEBUG
    if MobileDebugConfiguration.usesFixturesAtRuntime {
      try? await Task.sleep(for: .milliseconds(600))
      return
    }
    #endif
    guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
    await store.loadSites()
  }
}

private struct MobileSiteEditorView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var draft: SiteInfo
  @State private var preview: RssTestResponse?
  @State private var domainTest: SiteDomainTestResponse?
  @State private var showingDelete = false
  @State private var isSaving = false

  init(site: SiteInfo) {
    _draft = State(initialValue: site)
  }

  var body: some View {
    Form {
      Section("站点") {
        MobileFormTextField(label: "显示名称", prompt: "例如：OpenCD", text: optionalBinding(\.displayName))
        MobileFormTextField(label: "站点主地址", prompt: "例如：https://open.cd", text: optionalBinding(\.primaryUrl))
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
        MobileFormValidationMessage(message: primaryURLValidationMessage)
        Toggle("启用站点", isOn: boolBinding(\.enabled, fallback: true))
        if draft.supportsBrush == true {
          Toggle("仅用于站点刷流", isOn: boolBinding(\.brushOnly, fallback: false))
        }
        Stepper("超时 \(draft.timeoutSeconds ?? 15) 秒", value: intBinding(\.timeoutSeconds, fallback: 15), in: 5...120)
      }

      if draft.supportsRss {
        Section("RSS") {
          MobileFormSecureField(label: "RSS 地址", prompt: "已保存时留空保持不变", text: optionalBinding(\.rssUrl), reference: CredentialReference(scope: "site_settings", field: "rss_url", item: draft.id))
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
          MobileFormValidationMessage(message: rssURLValidationMessage)
          Button("预览 RSS", systemImage: "eye") {
            Task { preview = try? await store.previewSiteRSS(site: draft) }
          }
          .disabled(rssURLValidationMessage != nil)
        }
      }

      Section("认证") {
        if draft.authFields?.contains("cookie") == true || draft.authMode == "cookie" {
          MobileFormSecureField(
            label: "Cookie",
            prompt: draft.cookieConfigured == true ? "已配置，留空保持不变" : "输入站点 Cookie",
            text: optionalBinding(\.cookie),
            reference: CredentialReference(scope: "site_settings", field: "cookie", item: draft.id)
          )
          if draft.cookieConfigured == true { Toggle("清除已保存 Cookie", isOn: boolBinding(\.clearCookie, fallback: false)) }
        }
        if draft.authFields?.contains("api_key") == true {
          MobileFormSecureField(
            label: "API Key",
            prompt: draft.apiKeyConfigured == true ? "已配置，留空保持不变" : "输入 API Key",
            text: optionalBinding(\.apiKey),
            reference: CredentialReference(scope: "site_settings", field: "api_key", item: draft.id)
          )
          if draft.apiKeyConfigured == true { Toggle("清除已保存 API Key", isOn: boolBinding(\.clearApiKey, fallback: false)) }
        }
        if draft.authFields?.contains("passkey") == true {
          MobileFormSecureField(
            label: "Passkey",
            prompt: draft.passkeyConfigured == true ? "已配置，留空保持不变" : "输入 Passkey",
            text: optionalBinding(\.passkey),
            reference: CredentialReference(scope: "site_settings", field: "passkey", item: draft.id)
          )
          if draft.passkeyConfigured == true { Toggle("清除已保存 Passkey", isOn: boolBinding(\.clearPasskey, fallback: false)) }
        }
        if draft.authFields?.contains("authorization") == true {
          MobileFormSecureField(
            label: "Authorization",
            prompt: draft.authorizationConfigured == true ? "已配置，留空保持不变" : "输入认证值",
            text: optionalBinding(\.authorization),
            reference: CredentialReference(scope: "site_settings", field: "authorization", item: draft.id)
          )
          if draft.authorizationConfigured == true { Toggle("清除已保存 Authorization", isOn: boolBinding(\.clearAuthorization, fallback: false)) }
        }
        if draft.requestHeadersConfigured == true {
          MobileFormSecureField(label: "旧版请求头", prompt: "已保存",
            text: .constant(""), reference: CredentialReference(scope: "site_settings", field: "request_headers", item: draft.id))
        }
        Text("凭证保存在后端，不写入 iPhone 的偏好设置。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("连通性") {
        Button("测试站点地址", systemImage: "network") {
          Task { domainTest = try? await store.testSiteDomain(siteID: draft.id, url: draft.primaryUrl ?? draft.baseUrl ?? "") }
        }
        .disabled(primaryURLValidationMessage != nil)
        if let domainTest {
          Label(domainTest.message, systemImage: domainTest.ok ? "checkmark.circle" : "exclamationmark.triangle")
            .foregroundStyle(domainTest.ok ? .green : .orange)
        }
      }

      Section {
        Button("移除站点", systemImage: "trash", role: .destructive) { showingDelete = true }
      }
    }
    .mobileStatusNavigationTitle(draft.label)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("保存") {
          Task {
            isSaving = true
            let saved = await store.saveSite(draft)
            isSaving = false
            if saved { dismiss() }
          }
        }
        .disabled(isSaving || hasURLValidationError)
      }
    }
    .sheet(isPresented: Binding(
      get: { preview != nil },
      set: { if !$0 { preview = nil } }
    )) {
      if let response = preview {
        NavigationStack {
          List(response.results) { result in
            MobileSearchResultSummary(result: result)
          }
          .mobileStatusNavigationTitle("RSS 预览 · \(response.count)")
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { preview = nil } } }
        }
      }
    }
    .alert("移除站点？", isPresented: $showingDelete) {
      Button("移除", role: .destructive) {
        Task { if await store.deleteSite(draft) { dismiss() } }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("会移除 Kisetsu 中的站点配置，不会修改站点账户。")
    }
  }

  private func optionalBinding(_ keyPath: WritableKeyPath<SiteInfo, String?>) -> Binding<String> {
    Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
  }

  private var primaryURLValidationMessage: String? {
    MobileFormValidation.httpURLMessage(
      draft.primaryUrl ?? draft.baseUrl ?? "",
      field: "站点主地址"
    )
  }

  private var rssURLValidationMessage: String? {
    MobileFormValidation.httpURLMessage(draft.rssUrl ?? "", field: "RSS 地址", allowsEmpty: true)
  }

  private var hasURLValidationError: Bool {
    primaryURLValidationMessage != nil || rssURLValidationMessage != nil
  }

  private func boolBinding(_ keyPath: WritableKeyPath<SiteInfo, Bool?>, fallback: Bool) -> Binding<Bool> {
    Binding(get: { draft[keyPath: keyPath] ?? fallback }, set: { draft[keyPath: keyPath] = $0 })
  }

  private func intBinding(_ keyPath: WritableKeyPath<SiteInfo, Int?>, fallback: Int) -> Binding<Int> {
    Binding(get: { draft[keyPath: keyPath] ?? fallback }, set: { draft[keyPath: keyPath] = $0 })
  }
}

private struct MobileSearchResultSummary: View {
  @EnvironmentObject private var store: AppStore
  var result: SearchResult

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(result.title).font(.subheadline.weight(.medium)).lineLimit(3)
      Text([store.siteLabel(for: result.source), result.size, result.publishedAt].compactMap { $0 }.joined(separator: " · "))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
