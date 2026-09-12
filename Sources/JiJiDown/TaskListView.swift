import JiJiKit
import JiJiProtos
import SwiftUI

struct TaskListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.tasks.isEmpty {
                ContentUnavailableView {
                    Label("还没有任务", systemImage: "tray")
                } description: {
                    Text("去「下载」页粘贴一个 B 站链接。")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.tasks, id: \.taskID) { task in
                            TaskRow(task: task)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refreshTasks() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(!model.core.phase.isRunning)
            }
        }
    }
}

private struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: Jijidown_Core_TaskStatusReply

    private var progress: Jijidown_Core_TaskProgress { task.progress }

    /// 核心不填 `task_title`，标题得从客户端的配对表里取；都取不到才退回任务 id。
    private var title: String {
        let known = model.title(for: task.taskID)
        if !known.isEmpty { return known }
        if !task.taskTitle.isEmpty { return task.taskTitle }
        return "任务 \(task.taskID.prefix(8))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(task.displayLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(task.tint)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(task.tint.opacity(0.14), in: Capsule())

                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Controls(task: task)
            }

            ProgressView(value: Double(progress.progress), total: 100)
                .tint(task.tint)

            HStack(spacing: 12) {
                Text("\(progress.progress)%")
                if !progress.downloadSpeed.isEmpty {
                    Label(progress.downloadSpeed, systemImage: "speedometer")
                }
                if !progress.eta.isEmpty {
                    Label(progress.eta, systemImage: "clock")
                }
                if !progress.completedLength.isEmpty || !progress.totalLength.isEmpty {
                    Text("\(Fmt.orDash(progress.completedLength)) / \(Fmt.orDash(progress.totalLength))")
                }
                if !task.videoBadge.isEmpty { Text(task.videoBadge) }
                Spacer()
                if !task.savePath.isEmpty {
                    Text(task.savePath)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct Controls: View {
    @Environment(AppModel.self) private var model
    let task: Jijidown_Core_TaskStatusReply

    var body: some View {
        HStack(spacing: 4) {
            // 已完成/出错的任务不给「暂停」「继续」—— 它们没有意义。
            // 注意判据是 `isFinished` 而不是 `taskStatus == .taskComplete`：
            // 核心下完后状态停在 GENMUSIC，等号右边永远不成立。
            if !task.isFinished && task.taskStatus != .taskError {
                switch task.taskStatus {
                case .taskRunning:
                    iconButton("pause.fill", "暂停") { await model.control(task.taskID, .pause) }
                case .taskPause:
                    iconButton("play.fill", "继续") { await model.control(task.taskID, .resume) }
                default:
                    EmptyView()
                }
            }
            if task.isFinished {
                iconButton("folder", "在访达中显示") { model.revealLastDownload() }
            }
            iconButton("trash", "仅删除任务") { await model.control(task.taskID, .delete) }
            iconButton("trash.slash", "删除任务和文件") {
                await model.control(task.taskID, .deleteAndFile)
            }
        }
        .buttonStyle(.borderless)
    }

    private func iconButton(
        _ symbol: String, _ help: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .help(help)
    }
}
