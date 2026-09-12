import AppKit
import SwiftUI

enum DesktopDebugConfiguration {
  private static func value(_ key: String, legacyKey: String) -> String? {
    let environment = ProcessInfo.processInfo.environment
    return environment[key] ?? environment[legacyKey]
  }

  static var usesPlaylistFixtures: Bool {
#if DEBUG
    value("KISETSU_DESKTOP_USE_FIXTURES", legacyKey: "ANIMEPILOT_DESKTOP_USE_FIXTURES") == "1"
#else
    false
#endif
  }

  static var initialSection: String? {
#if DEBUG
    value("KISETSU_DESKTOP_INITIAL_SECTION", legacyKey: "ANIMEPILOT_DESKTOP_INITIAL_SECTION")
#else
    nil
#endif
  }

  static var initialPlaylistDetail: String? {
#if DEBUG
    value(
      "KISETSU_DESKTOP_INITIAL_PLAYLIST_DETAIL",
      legacyKey: "ANIMEPILOT_DESKTOP_INITIAL_PLAYLIST_DETAIL"
    )
#else
    nil
#endif
  }
}

@main
struct KisetsuApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store: AppStore
  @FocusedValue(\.focusSubscriptionSearch) private var focusSubscriptionSearch

  init() {
    let defaults = DesktopDebugConfiguration.usesPlaylistFixtures
      ? UserDefaults(suiteName: "Kisetsu.Desktop.Fixture")! : .standard
    let appStore = AppStore(backendUserDefaults: defaults)
    #if DEBUG
    if DesktopDebugConfiguration.usesPlaylistFixtures {
      if let url = ProcessInfo.processInfo.environment["KISETSU_DESKTOP_ORGANIZE_FIXTURE_URL"],
         let components = URLComponents(string: url), components.scheme == "http",
         components.host == "127.0.0.1", components.port != nil {
        appStore.fixtureClient = APIClient(baseURL: url)
      } else {
        appStore.fixtureClient = APIClient(baseURL: "https://kisetsu-fixture.invalid") { _ in
          throw URLError(.notConnectedToInternet)
        }
      }
      appStore.sites = DesktopDebugFixtureData.sites
      appStore.sitesLoaded = true
      appStore.subscriptions = DesktopDebugFixtureData.subscriptions
      if DesktopDebugConfiguration.initialSection == "dashboard" {
        appStore.overview = OverviewDebugFixtures.overview(subscriptions: appStore.subscriptions)
      }
    }
    #endif
    _store = StateObject(wrappedValue: appStore)
  }

  private var forcedColorScheme: ColorScheme? {
    let environment = ProcessInfo.processInfo.environment
    let value = environment["KISETSU_COLOR_SCHEME"] ?? environment["ANIMEPILOT_COLOR_SCHEME"]
    switch value?.lowercased() {
    case "dark":
      return .dark
    case "light":
      return .light
    default:
      return nil
    }
  }

  var body: some Scene {
    WindowGroup("Kisetsu", id: "main") {
      ContentView()
        .environmentObject(store)
        .preferredColorScheme(forcedColorScheme)
        .task {
          if DesktopDebugConfiguration.usesPlaylistFixtures {
            #if DEBUG
            if ProcessInfo.processInfo.environment["KISETSU_DESKTOP_ORGANIZE_FIXTURE_URL"] != nil {
              await store.loadOrganizeTargets()
              // Await this fixture request, independent of the task page's polling load.
              if let items = try? await store.fixtureClient?.history() {
                store.history = items
                if let item = items.first { await store.previewHistoryItem(item) }
              }
            }
            #endif
            return
          }
          await store.bootstrap()
        }
    }
    .commands {
      CommandMenu("Kisetsu") {
        Button("搜索订阅") {
          focusSubscriptionSearch?()
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(focusSubscriptionSearch == nil)

        Divider()

        Button("刷新全部状态") {
          Task { await store.bootstrap() }
        }
        .keyboardShortcut("r")
        .disabled(store.isBootstrapping)
      }
    }

    Settings {
      SettingsView()
        .environmentObject(store)
    }
  }
}

#if DEBUG
private enum DesktopDebugFixtureData {
  static let sites = [
    SiteInfo(
      id: "mteam",
      name: "M-Team",
      displayName: "M-Team",
      baseUrl: nil,
      primaryUrl: nil,
      mirrors: [],
      activeBaseUrl: nil,
      enabled: true,
      supportsSearch: true,
      supportsRss: true
    ),
    SiteInfo(
      id: "mikan",
      name: "Mikan",
      displayName: "Mikan Project",
      baseUrl: nil,
      primaryUrl: nil,
      mirrors: [],
      activeBaseUrl: nil,
      enabled: true,
      supportsSearch: true,
      supportsRss: true
    ),
  ]

  static let subscriptions: [Subscription] = {
    let json = """
    [
      {
        "id": 910001,
        "name": "脱敏订阅示例",
        "keyword": "脱敏订阅示例",
        "sourceType": "keyword",
        "sites": ["mteam"],
        "aliases": [],
        "rssUrls": [],
        "regexEnabled": false,
        "includeKeywords": [],
        "excludeKeywords": [],
        "filterOrder": "include_then_exclude",
        "fansub": "示例字幕组",
        "resolution": "2160p",
        "resolutionMode": "preset",
        "resolutionPreset": "2160p",
        "season": 1,
        "episodeStart": 3,
        "episodeOffset": 0,
        "episodeParseRules": [],
        "totalEpisodes": 12,
        "enabled": true,
        "autoDownload": true,
        "autoOrganize": true,
        "tags": [],
        "createdAt": "2026-08-20T10:00:00Z",
        "matchedCount": 8,
        "queuedCount": 0,
        "skippedCount": 2,
        "errorCount": 0,
        "downloadedCount": 6,
        "organizedCount": 5,
        "metadataBindingCount": 1,
        "metadataTitles": ["脱敏别名 / Fixture Title"],
        "summary": "用于界面验收的脱敏番组简介。",
        "posterPalette": {
          "primary": "#B44762",
          "secondary": "#E39AAD",
          "accent": "#D75F7D",
          "background": "#F5D7DF",
          "textContrast": "#1C1C1E"
        },
        "coverage": {
          "totalEpisodes": 12,
          "catalogTotalEpisodes": 12,
          "targetTotalEpisodes": 10,
          "skippedBeforeStart": 2,
          "downloadedCount": 6,
          "organizedCount": 5,
          "downloadedRanges": ["3-8"],
          "organizedRanges": ["3-7"],
          "hasBatchDownload": false,
          "hasBatchOrganized": false
        }
      },
      {
        "id": 910002,
        "name": "脱敏订阅二",
        "keyword": "Fixture Anime Two",
        "sourceType": "keyword",
        "sites": ["mikan"],
        "aliases": [],
        "rssUrls": [],
        "regexEnabled": false,
        "includeKeywords": [],
        "excludeKeywords": [],
        "filterOrder": "include_then_exclude",
        "fansub": "联合字幕组",
        "resolution": "1080p",
        "resolutionMode": "preset",
        "resolutionPreset": "1080p",
        "season": 1,
        "episodeStart": 1,
        "episodeOffset": 0,
        "episodeParseRules": [],
        "totalEpisodes": 12,
        "enabled": true,
        "autoDownload": true,
        "autoOrganize": true,
        "tags": [],
        "createdAt": "2026-08-20T11:00:00Z",
        "matchedCount": 12,
        "queuedCount": 0,
        "skippedCount": 0,
        "errorCount": 0,
        "downloadedCount": 8,
        "organizedCount": 8,
        "metadataBindingCount": 1,
        "metadataTitles": ["Fixture Anime Two"],
        "summary": "第二个脱敏订阅的简介内容。",
        "posterPalette": {
          "primary": "#2E7D6F",
          "secondary": "#79B7AA",
          "accent": "#3F9C89",
          "background": "#B8DDD5",
          "textContrast": "#1C1C1E"
        },
        "coverage": {
          "totalEpisodes": 12,
          "catalogTotalEpisodes": 12,
          "targetTotalEpisodes": 12,
          "skippedBeforeStart": 0,
          "downloadedCount": 8,
          "organizedCount": 8,
          "downloadedRanges": ["1-8"],
          "organizedRanges": ["1-8"],
          "hasBatchDownload": false,
          "hasBatchOrganized": false
        }
      }
    ]
    """
    return (try? JSONDecoder().decode([Subscription].self, from: Data(json.utf8))) ?? []
  }()
}
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}
