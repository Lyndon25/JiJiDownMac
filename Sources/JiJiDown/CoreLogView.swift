import JiJiKit
import SwiftUI

struct CoreLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(model.core.phase.tint).frame(width: 8, height: 8)
                Text(model.core.phase.label).font(.callout)
                if !model.core.coreVersion.isEmpty {
                    Text(model.core.coreVersion)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("自动滚动", isOn: $model.autoScroll).toggleStyle(.checkbox)

                Button(model.core.phase.isRunning ? "停止核心" : "启动核心") {
                    if model.core.phase.isRunning {
                        model.shutdown()
                    } else {
                        Task { await model.bootCore() }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.core.log.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: model.core.log.count) {
                    guard model.autoScroll, let last = model.core.log.indices.last else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}
