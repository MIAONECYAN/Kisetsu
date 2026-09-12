import CoreGraphics
import ImageIO
import SwiftUI

private final class MobilePosterObject: @unchecked Sendable {
  let image: CGImage
  let cost: Int

  init(_ image: CGImage) {
    self.image = image
    cost = image.bytesPerRow * image.height
  }
}

private actor MobilePosterPipeline {
  static let shared = MobilePosterPipeline()

  private let cache = NSCache<NSString, MobilePosterObject>()
  private var inFlight: [String: Task<MobilePosterObject?, Never>] = [:]

  init() {
    cache.countLimit = 100
    cache.totalCostLimit = 48 * 1_024 * 1_024
  }

  func image(url: URL, maxPixelSize: Int) async -> CGImage? {
    let bucket = [192, 256, 384, 512, 768, 1024].first(where: { maxPixelSize <= $0 }) ?? maxPixelSize
    let key = "\(url.absoluteString)#\(bucket)"
    if let cached = cache.object(forKey: key as NSString) {
      return cached.image
    }
    if let existing = inFlight[key] {
      return await existing.value?.image
    }
    let task = Task.detached(priority: .utility) { () -> MobilePosterObject? in
      do {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
          return nil
        }
        let options: [CFString: Any] = [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
          kCGImageSourceThumbnailMaxPixelSize: bucket,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
          return nil
        }
        return MobilePosterObject(image)
      } catch {
        return nil
      }
    }
    inFlight[key] = task
    let loaded = await task.value
    inFlight[key] = nil
    if let loaded {
      cache.setObject(loaded, forKey: key as NSString, cost: loaded.cost)
    }
    return loaded?.image
  }

  func removeAll() {
    inFlight.values.forEach { $0.cancel() }
    inFlight.removeAll()
    cache.removeAllObjects()
  }
}

struct MobilePosterImage: View {
  @Environment(\.displayScale) private var displayScale
  @State private var image: CGImage?
  var urls: [URL]
  var width: CGFloat
  var height: CGFloat
  var cornerRadius: CGFloat
  var showsPlaceholderSymbol: Bool

  init(url: URL?, width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 8, showsPlaceholderSymbol: Bool = true) {
    urls = url.map { [$0] } ?? []
    self.width = width
    self.height = height
    self.cornerRadius = cornerRadius
    self.showsPlaceholderSymbol = showsPlaceholderSymbol
  }

  init(urls: [URL?], width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 8, showsPlaceholderSymbol: Bool = true) {
    var seen = Set<String>()
    self.urls = urls.compactMap { $0 }.filter { seen.insert($0.absoluteString).inserted }
    self.width = width
    self.height = height
    self.cornerRadius = cornerRadius
    self.showsPlaceholderSymbol = showsPlaceholderSymbol
  }

  var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: displayScale)
          .resizable()
          .scaledToFill()
      } else {
        ZStack {
          Color.pink.opacity(0.13)
          if showsPlaceholderSymbol {
            Image(systemName: "sparkles.tv")
              .font(.title2)
              .foregroundStyle(.pink.opacity(0.72))
          }
        }
      }
    }
    .frame(width: width, height: height)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .stroke(.primary.opacity(0.08), lineWidth: 0.5)
    }
    .task(id: requestKey) {
      image = nil
      let maxPixelSize = Int(ceil(max(width, height) * displayScale))
      for url in urls {
        if !MobileDebugConfiguration.shouldLoadNetworkAtRuntime {
          #if DEBUG
          guard MobileDebugConfiguration.usesFixturesAtRuntime,
                let base = ProcessInfo.processInfo.environment["KISETSU_OVERVIEW_ARTWORK_BASE"],
                let fixtureURL = URL(string: base), fixtureURL.host == "127.0.0.1",
                fixtureURL.scheme == "http", url.host == fixtureURL.host,
                url.port == fixtureURL.port, url.scheme == fixtureURL.scheme else { continue }
          #else
          continue
          #endif
        }
        guard !Task.isCancelled else { return }
        if let loaded = await MobilePosterPipeline.shared.image(url: url, maxPixelSize: maxPixelSize) {
          guard !Task.isCancelled else { return }
          image = loaded
          return
        }
      }
    }
    .accessibilityHidden(true)
  }

  private var requestKey: String {
    "\(urls.map(\.absoluteString).joined(separator: "|"))#\(width)x\(height)#\(displayScale)"
  }
}
