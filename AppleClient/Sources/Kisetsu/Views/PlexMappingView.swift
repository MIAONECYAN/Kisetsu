import SwiftUI

struct PlexMappingView: View {
  @EnvironmentObject private var store: AppStore

  private var yearBinding: Binding<String> {
    Binding {
      store.mapping.showYear.map(String.init) ?? ""
    } set: { value in
      store.mapping.showYear = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  var body: some View {
    Form {
      Section("番剧信息") {
        TextField("识别键（高级）", text: $store.mapping.subjectKey)
        TextField("番剧目录名称", text: $store.mapping.showName)
        TextField("年份", text: yearBinding)
        if let suggested = store.metadataSuggestedMapping {
          Button {
            store.applySuggestedMapping()
          } label: {
            Label("使用识别建议", systemImage: "arrow.right.circle")
          }
          .disabled(store.isLoading || suggested.showName.isEmpty)
        }
      }

      Section("季与集数") {
        Stepper(value: $store.mapping.seasonNumber, in: 0...99) {
          LabeledContent("Season 编号", value: String(format: "%02d", store.mapping.seasonNumber))
        }
        Stepper(value: $store.mapping.episodeOffset, in: -999...999) {
          LabeledContent("集数偏移", value: "\(store.mapping.episodeOffset)")
        }
      }

      Section("已保存整理规则") {
        Button {
          Task { await store.loadPlexMappings() }
        } label: {
          Label("刷新整理规则", systemImage: "arrow.clockwise")
        }
        .disabled(store.isLoading)

        if store.plexMappings.isEmpty {
          Text("暂无保存的整理规则")
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.plexMappings) { record in
            Button {
              store.applyPlexMappingRecord(record)
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(record.mapping.showName)
                    .lineLimit(1)
                  Text("\(record.mapping.subjectKey) / Season \(String(format: "%02d", record.mapping.seasonNumber))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                if let year = record.mapping.showYear {
                  Text(String(year))
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }

      Section("资源") {
        TextField("源文件路径", text: $store.sourcePath)
        TextField("媒体库目录", text: $store.libraryRoot)
        TextField("原始文件名", text: $store.originalFilename)
        TextField("单集标题", text: $store.episodeTitle)
        HStack {
          Button {
            Task { await store.parseCurrentTitle() }
          } label: {
            Label("解析标题", systemImage: "text.magnifyingglass")
          }
          .disabled(store.isLoading)
          Button {
            Task { await store.saveMappingAndPreview() }
          } label: {
            Label("保存整理规则并生成预览", systemImage: "eye")
          }
          .disabled(store.isLoading)
          .help("保存当前整理规则并生成整理预览；执行整理前还需要在整理页单独确认。")
        }
      }

      if let parsed = store.parsedTitle {
        Section("解析结果") {
          LabeledContent("标题", value: parsed.title ?? parsed.originalTitle)
          LabeledContent("集数", value: parsed.episode.map(String.init) ?? "")
          LabeledContent("字幕组", value: parsed.fansub ?? "")
          LabeledContent("分辨率", value: parsed.resolution ?? "")
          LabeledContent("置信度", value: String(format: "%.2f", parsed.confidence))
        }
      }
    }
    .formStyle(.grouped)
    .padding(24)
    .frame(maxWidth: 760, alignment: .topLeading)
  }
}
