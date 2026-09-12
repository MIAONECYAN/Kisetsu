import Foundation

enum ManualOrganizePresentation {
  static func canApply(_ preview: OrganizePreviewItem) -> Bool {
    guard preview.canApply == true else { return false }
    let mappings = preview.fileMappings ?? []
    if mappings.isEmpty { return preview.batchMode != "multi_file" }
    let active = mappings.filter { $0.status != "skipped" }
    return !active.isEmpty && active.allSatisfy { $0.status == "ready" }
  }
}

struct ManualOrganizeScope: Equatable {
  var requiresMultipleFiles: Bool
  var episodeStart: Int?
  var episodeEnd: Int?

  static func resolve(history: DownloadHistory?, parsed: ParsedAnimeTitle?) -> ManualOrganizeScope {
    resolve(
      historyResourceType: history?.resourceType,
      historyIsBatch: history?.isBatch,
      historyIsMultiEpisode: history?.isMultiEpisode,
      historyEpisodeStart: history?.seasonEpisodeStart ?? history?.episodeStart,
      historyEpisodeEnd: history?.seasonEpisodeEnd ?? history?.episodeEnd,
      parsed: parsed
    )
  }

  static func resolve(
    historyResourceType: String?,
    historyIsBatch: Bool?,
    historyIsMultiEpisode: Bool?,
    historyEpisodeStart: Int?,
    historyEpisodeEnd: Int?,
    parsed: ParsedAnimeTitle?
  ) -> ManualOrganizeScope {
    let start = historyEpisodeStart ?? parsed?.seasonEpisodeStart ?? parsed?.episodeStart ?? parsed?.episode
    let end = historyEpisodeEnd ?? parsed?.seasonEpisodeEnd ?? parsed?.episodeEnd ?? start
    let parsedResourceType = parsed?.resourceType
    let requiresMultipleFiles = historyIsBatch == true ||
      historyIsMultiEpisode == true ||
      historyResourceType == "batch" ||
      historyResourceType == "episode_range" ||
      parsed?.isBatch == true ||
      parsed?.isMultiEpisode == true ||
      parsedResourceType == "batch" ||
      parsedResourceType == "episode_range" ||
      (start != nil && end != nil && start != end)
    return ManualOrganizeScope(
      requiresMultipleFiles: requiresMultipleFiles,
      episodeStart: start,
      episodeEnd: end
    )
  }
}

struct ManualMetadataCandidateSelection: Equatable {
  var subjectKey: String
  var showName: String
  var originalTitle: String
  var year: Int?
  var seasonNumber: Int

  static func resolve(
    candidate: MetadataCandidate,
    parsed: ParsedAnimeTitle?,
    fallbackSeason: Int
  ) -> ManualMetadataCandidateSelection {
    let parsedSeason = parsed?.explicitSeasonNumber ??
      parsed?.effectiveSeasonNumber ??
      parsed?.seasonNumber ??
      parsed?.season
    return ManualMetadataCandidateSelection(
      subjectKey: candidate.id,
      showName: candidate.chineseTitle ?? candidate.title,
      originalTitle: candidate.originalTitle ?? candidate.title,
      year: candidate.airDate.flatMap { Int($0.prefix(4)) },
      seasonNumber: max(0, parsedSeason ?? candidate.seasonNumber ?? fallbackSeason)
    )
  }
}

struct ManualOrganizeOperationState: Equatable {
  private(set) var isRunning = false
  private(set) var feedback: OperationStatus?

  mutating func begin() {
    isRunning = true
    feedback = nil
  }

  mutating func finish() {
    isRunning = false
  }

  mutating func fail(title: String, detail: String) {
    isRunning = false
    feedback = OperationStatus(
      phase: .failed,
      title: title,
      detail: detail,
      updatedAt: Date()
    )
  }

  mutating func dismiss(feedbackID: UUID? = nil) {
    guard feedbackID == nil || feedback?.id == feedbackID else { return }
    feedback = nil
  }

  mutating func reset() {
    isRunning = false
    feedback = nil
  }
}
