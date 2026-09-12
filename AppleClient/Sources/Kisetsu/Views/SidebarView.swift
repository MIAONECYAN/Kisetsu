import SwiftUI

struct SidebarView: View {
  @Binding var selection: AppSection?

  var body: some View {
    List(selection: $selection) {
      Section {
        ForEach(AppSection.allCases) { section in
          Label {
            Text(section.title)
              .font(.body.weight(selection == section ? .medium : .regular))
          } icon: {
            Image(systemName: section.symbol)
              .symbolRenderingMode(.hierarchical)
          }
          .tag(section)
        }
      } header: {
        VStack(alignment: .leading, spacing: 3) {
          Text("Kisetsu")
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
          Text("媒体库助手")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
      }
    }
    .scrollContentBackground(.hidden)
    .listStyle(.sidebar)
    .background(.regularMaterial)
    .navigationSplitViewColumnWidth(min: 176, ideal: 190, max: 220)
  }
}
