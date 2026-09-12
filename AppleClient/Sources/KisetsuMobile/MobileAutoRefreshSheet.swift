import SwiftUI

struct MobileAutoRefreshSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model: MobileAutoRefreshState
  @FocusState private var editingInterval: Bool

  init(client: APIClient) {
    _model = StateObject(wrappedValue: MobileAutoRefreshState(client: client))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack {
            Text("当前状态")
            Spacer()
            if model.isBusy {
              ProgressView().accessibilityLabel("正在读取或提交")
            } else if let status = model.status {
              Label(status.running ? "已开启" : "已停止", systemImage: status.running ? "clock.arrow.circlepath" : "pause.circle")
                .foregroundStyle(.secondary)
            } else {
              Text("未能读取").foregroundStyle(.secondary)
            }
          }
          HStack {
            Text("刷新间隔")
            TextField("间隔", text: $model.intervalText)
              .keyboardType(.numberPad)
              .multilineTextAlignment(.trailing)
              .focused($editingInterval)
              .accessibilityLabel("刷新间隔")
            Picker("单位", selection: Binding(get: { model.unit }, set: { model.changeUnit(to: $0) })) {
              Text("分钟").tag(MobileAutoRefreshState.Unit.minutes)
              Text("秒").tag(MobileAutoRefreshState.Unit.seconds)
            }
            .labelsHidden()
            .fixedSize()
          }
          .disabled(model.isBusy || model.status == nil)
        } footer: {
          if model.status != nil && model.intervalSeconds == nil {
            Text("刷新间隔须为 1–86400 秒。")
          } else {
            Text("修改间隔不改变启停状态；运行中的当前周期保持不变。")
          }
        }

        if let message = model.errorMessage {
          Section {
            Text(message).font(.footnote).foregroundStyle(.red)
            Button("重新读取", systemImage: "arrow.clockwise") {
              Task { await model.load() }
            }
            .disabled(model.isBusy)
          }
        }

        if let status = model.status {
          Section {
            Button(status.running ? "停止自动刷新" : "开启自动刷新", systemImage: status.running ? "pause.fill" : "play.fill") {
              editingInterval = false
              Task { await model.perform(status.running ? .stop : .start) }
            }
            .disabled(model.isBusy || (!status.running && model.intervalSeconds == nil))
            .frame(minHeight: 44)
          }
        }
      }
      .navigationTitle("自动刷新")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭", systemImage: "xmark") { dismiss() }
            .labelStyle(.iconOnly)
            .disabled(model.isBusy)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存", systemImage: "checkmark") {
            editingInterval = false
            Task { await model.perform(.save) }
          }
          .labelStyle(.iconOnly)
          .disabled(model.isBusy || model.status == nil || !model.hasChanges || model.intervalSeconds == nil)
        }
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("完成") { editingInterval = false }
        }
      }
      .task { await model.load() }
      .onDisappear { model.invalidate() }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await model.load() } }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .interactiveDismissDisabled(model.isBusy)
  }
}
