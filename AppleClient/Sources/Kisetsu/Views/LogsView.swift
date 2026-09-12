import SwiftUI

struct LogsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var confirmClearLogs = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button {
          confirmClearLogs = true
        } label: {
          Label("清空日志", systemImage: "trash")
        }
        .disabled(store.logs.isEmpty)
        Spacer()
      }
      .appToolbarSurface()

      if store.logs.isEmpty {
        ContentUnavailableView("暂无日志", systemImage: "doc.text")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(store.logs, id: \.self) { line in
          Text(line)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
      }
    }
    .alert("清空日志？", isPresented: $confirmClearLogs) {
      Button("取消", role: .cancel) {}
      Button("清空", role: .destructive) {
        store.clearLogs()
      }
    } message: {
      Text("将清空当前本地操作日志列表，不会删除订阅、下载记录或媒体文件。")
    }
  }
}
