import SwiftUI

struct MetadataReviewSheet: View {
  @EnvironmentObject private var store: AppStore
  var close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("确认番剧信息")
            .font(.title3.weight(.semibold))
          Text(reviewSubtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Button {
          store.skipMetadataRecognition()
          close()
        } label: {
          Label("跳过", systemImage: "forward.end")
        }
        .disabled(store.metadataBindingCandidateID != nil)
        Button {
          close()
        } label: {
          Label("关闭", systemImage: "xmark.circle")
        }
        .disabled(store.metadataBindingCandidateID != nil)
      }
      .padding()

      Divider()

      MetadataMatchView()
    }
    .frame(minWidth: 860, idealWidth: 980, minHeight: 680, idealHeight: 760)
  }

  private var reviewSubtitle: String {
    let trimmed = store.metadataQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return "选择一个候选后会保存为当前订阅或资源的番剧信息"
    }
    return trimmed
  }
}

struct MetadataMatchView: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    VStack(spacing: 0) {
      MetadataSearchControls(
        query: $store.metadataQuery,
        isLoading: store.isLoading,
        onSearchAll: { Task { await store.searchMetadata() } },
        onSearchBangumi: { Task { await store.searchBangumiMetadata() } },
        onSearchTMDB: { Task { await store.searchTMDBMetadata() } }
      )
      .padding()

      MetadataSuggestionBar()
      MetadataWarningBar()
      MetadataTargetBar()

      Divider()

      MetadataCandidateList()
    }
  }
}

struct MetadataSearchControls: View {
  @Binding var query: String
  var isLoading: Bool
  var onSearchAll: () -> Void
  var onSearchBangumi: () -> Void
  var onSearchTMDB: () -> Void
  var includesBangumi = true

  private var searchDisabled: Bool {
    isLoading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        searchField
        sourceButtons
      }
      VStack(alignment: .leading, spacing: 8) {
        searchField
        sourceButtons
      }
    }
  }

  private var searchField: some View {
    TextField("作品名称", text: $query, prompt: Text("中文、日文或英文名称"))
      .textFieldStyle(.roundedBorder)
      .onSubmit(onSearchAll)
  }

  private var sourceButtons: some View {
    HStack(spacing: 8) {
      Button(action: onSearchAll) {
        Label(isLoading ? "搜索中..." : "搜索全部", systemImage: "magnifyingglass")
      }
      .disabled(searchDisabled)
      .help(includesBangumi ? "同时搜索 Bangumi 和 TMDB" : "搜索 TMDB 电影")
      if includesBangumi {
      Button(action: onSearchBangumi) {
        Label("搜索 Bangumi", systemImage: "circle.grid.cross")
      }
      .disabled(searchDisabled)
      .help("只搜索 Bangumi 候选")
      }
      Button(action: onSearchTMDB) {
        Label("搜索 TMDB", systemImage: "film")
      }
      .disabled(searchDisabled)
      .help("只搜索 TMDB 候选")
    }
  }
}

struct MetadataWarningBar: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    if !store.metadataWarnings.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(store.metadataWarnings, id: \.self) { warning in
          Label(StatusLabels.message(warning), systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal)
      .padding(.bottom, 10)
    }
  }
}

private struct MetadataCandidateList: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    if store.metadataCandidates.isEmpty {
      ContentUnavailableView("暂无番剧候选", systemImage: "film.stack", description: Text("搜索或从资源列表点击“识别番剧”后会显示 Bangumi / TMDB 候选。"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List(store.metadataCandidates) { candidate in
        MetadataCandidateRow(
          candidate: candidate,
          isRecommended: candidate.id == store.metadataRecommendedCandidateID,
          isSelected: false,
          actionTitle: "使用此番剧信息",
          actionHelp: "把这个候选保存为当前资源的番剧识别结果",
          isActionInProgress: store.metadataBindingCandidateID == candidate.id,
          actionDisabled: store.isLoading || store.metadataBindingCandidateID != nil,
          onSelect: { Task { await store.bind(candidate) } }
        )
      }
    }
  }
}

struct MetadataCandidateRow: View {
  var candidate: MetadataCandidate
  var isRecommended: Bool
  var isSelected: Bool
  var actionTitle: String
  var actionHelp: String
  var isActionInProgress: Bool
  var actionDisabled: Bool
  var onSelect: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(candidate.title)
          .font(.headline)
        if isSelected {
          Label("已选择", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.tint)
        } else if isRecommended {
          Label("推荐", systemImage: "checkmark.seal")
            .font(.caption)
            .foregroundStyle(.green)
        }
        Text(candidate.source.uppercased())
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if let url = metadataDetailURL(for: candidate) {
          Link(destination: url) {
            Label("打开详情链接", systemImage: "safari")
          }
          .help("打开该候选在来源站点的公开页面")
        }
        Button(action: onSelect) {
          if isActionInProgress {
            HStack(spacing: 6) {
              ProgressView()
                .controlSize(.small)
              Text("保存中...")
            }
          } else {
            Label(actionTitle, systemImage: isSelected ? "checkmark.circle.fill" : "checkmark.seal")
          }
        }
        .disabled(actionDisabled)
        .help(actionHelp)
      }
      if let original = candidate.originalTitle, original != candidate.title {
        Text(original)
          .foregroundStyle(.secondary)
      }
      HStack {
        if let mediaType = candidate.mediaType {
          Text(mediaType == "movie" ? "电影" : "剧集")
        }
        if let date = candidate.airDate {
          Text(date)
        }
        if let rating = candidate.rating {
          Text(String(format: "评分 %.1f", rating))
        }
        if let episodes = candidate.totalEpisodes ?? candidate.episodeCount {
          Text("\(episodes) 集")
        }
        if let score = candidate.matchScore {
          Text("匹配 \(String(format: "%.2f", score))")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if !candidate.matchReason.isEmpty {
        Text(candidate.matchReason.joined(separator: "，"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      if let summary = candidate.summary, !summary.isEmpty {
        Text(summary)
          .font(.callout)
          .lineLimit(3)
      }
    }
    .padding(.vertical, 6)
  }
}

func metadataDetailURL(for candidate: MetadataCandidate) -> URL? {
    switch candidate.source {
    case "bangumi":
      return URL(string: "https://bgm.tv/subject/\(candidate.externalId)")
    case "tmdb":
      let type = candidate.mediaType == "movie" ? "movie" : "tv"
      return URL(string: "https://www.themoviedb.org/\(type)/\(candidate.externalId)")
    default:
      return nil
    }
}

private struct MetadataSuggestionBar: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    if store.metadataMergeSummary != nil || store.parsedTitle != nil || store.metadataSuggestedMapping != nil {
      VStack(alignment: .leading, spacing: 8) {
        if let parsed = store.parsedTitle {
          HStack {
            Label(parsed.title ?? parsed.originalTitle, systemImage: "text.magnifyingglass")
            if let episode = parsed.episode {
              Text("E\(episode)")
            }
            if let resolution = parsed.resolution {
              Text(resolution)
            }
            Text(String(format: "%.2f", parsed.confidence))
              .foregroundStyle(.secondary)
          }
          .font(.caption)
        }

        if let summary = store.metadataMergeSummary {
          Text(summary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let mapping = store.metadataSuggestedMapping {
          HStack {
            Label("\(mapping.showName) / Season \(String(format: "%02d", mapping.seasonNumber))", systemImage: "rectangle.stack")
              .font(.caption)
          }
        }
      }
      .padding(.horizontal)
      .padding(.bottom, 10)
    }
  }
}

private struct MetadataTargetBar: View {
  @EnvironmentObject private var store: AppStore

  private var targetLabel: String {
    let query = store.metadataQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = query.isEmpty ? "当前项目" : query
    if store.metadataTargetType == "subscription" {
      return "当前订阅：\(title)"
    }
    if store.metadataTargetID.hasPrefix("subscription-match:") {
      return "当前匹配资源：\(title)"
    }
    return "当前资源：\(title)"
  }

  var body: some View {
    HStack {
      Label("当前识别目标", systemImage: "scope")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(targetLabel)
        .font(.caption)
      Spacer()
    }
    .padding(.horizontal)
    .padding(.bottom, 8)
  }
}
