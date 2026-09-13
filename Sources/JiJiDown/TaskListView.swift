import JiJiKit
import JiJiProtos
import SwiftUI

struct TaskListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 没取到任务列表时必须在**这里**说出来：那时下面这几行是上一次取到的
            // 快照，任务在核心那边没有任何变化，但用户看到的是一份没刷新的旧数据。
            // 不说的话，界面和「核心那边真的没有任务」长得一模一样。
            if let reason = model.tasksError {
                NoticeLine(symbol: "exclamationmark.triangle.fill", tint: .orange, text: """
                    这次没取到任务列表：\(reason)

                    下面还列着的任务，那是上一次取到的内容 —— 任务在核心那边并没有\
                    被删掉，只是这个列表这一次没刷新成功。核心意外退出后自己重启\
                    （最长要等 60 秒就绪）或者一次瞬时的连接失败都会这样，**下一次\
                    刷新成功就会自己恢复**；如果一直不恢复，去「核心」页看它是不是\
                    起不来了。
                    """)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }

            // 任务控制（暂停 / 继续 / 删除）失败也要说出来。不说的话，界面会
            // 刷回核心那边的真实状态，而失败时那一行**原封不动** —— 用户点了
            // 「暂停」看到状态还写着「下载中」，只会以为界面没反应，反复点。
            if let actionError = model.taskActionError {
                NoticeLine(symbol: "exclamationmark.triangle.fill", tint: .orange, text: """
                    \(actionError)

                    下面列的任务就是核心那边的现状，所以操作没成功时，那一行看起来
                    和点之前一模一样 —— 那是因为核心那边根本没变，不是界面没反应。

                    两种情形客户端分不出来：一是按钮按下去的那一瞬间任务刚好走完
                    （列表每 2 秒才刷一次，界面上的状态最多滞后 2 秒），那种情况本来
                    就没有东西可暂停 / 可继续；二是核心不接受在它当前状态下做这个
                    动作，这一种核心只回了上面那一句，没有更多解释。

                    先看那一行现在的状态：要是已经变成「已完成」，就是第一种，不用
                    再管；要是还是老样子，去「核心」页看一眼日志里那段时间的记录。
                    """)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }

            if model.tasks.isEmpty {
                // 取失败时上面那行已经把话说完了，这里**不能再摆一句「还没有任务」**
                // —— 两句话会打架，而用户会信更醒目的那一句。
                if model.tasksError == nil {
                    ContentUnavailableView {
                        Label("还没有任务", systemImage: "tray")
                    } description: {
                        Text("去「下载」页粘贴一个 B 站链接。")
                    }
                } else {
                    Spacer()
                }
            } else {
                // 配不上标题的任务要在这里说出来（`AppModel.unpairedTaskIDs` 的
                // 注释里承诺过），但**别把它说成「产物找不到」** —— 配不上对只
                // 影响标题用哪个名字显示，定位产物用的是核心回显的主干名，那一条
                // 照样记着。说反了就会把用户往「文件丢了」的错误方向带。
                if model.hasUnpairedTasks {
                    NoticeLine(symbol: "questionmark.circle", tint: .secondary, text: """
                        列表里有 \(model.unpairedTaskIDs.count) 个任务没在本地标题对照表里\
                        配上对：多半是命令行探针 / 官方客户端 / 另一个实例建的任务（它们跑在\
                        同一个核心上，也会出现在这里），或者是本 App 重启之前建的\
                        （对照表只在内存里，重启就空了）。

                        这些行显示的是核心回显的文件主干名 —— 它就是产物的名字，\
                        **「在访达中显示」照常可用**。配不上对只意味着我们叫不出\
                        提交时那个标题。
                        """)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
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

    /// 标题的三级回退：本地对照表 → 核心回显的主干名 → 任务 id。
    ///
    /// 第一级是提交时那个原标题，靠**核心回显的 `task_title`** 配对：实测核心把它
    /// 设成我们提交的 `TaskNewReq.save_filename` 原样回显（不传时才是空串），
    /// 与列表顺序无关，这是唯一可靠的凭据（见 `AppModel.claimNewTasks`）。
    ///
    /// 第二级（`task.taskTitle`）不是多余的兜底，删不得：探针 / 官方客户端 /
    /// 另一个实例建的任务，以及本 App 重启前建的（对照表只在内存里，重启即空）
    /// 都配不上对，那几行的标题只剩核心回显的主干名 —— 它**就是产物的名字**，
    /// 是真名不是猜的。少了这一级，这些任务在界面上全部变成「任务 abc12345」。
    ///
    /// **不要退回按列表顺序认领**：实测同一份列表连读两次顺序就会翻转，那样配
    /// 出来的是错标题。
    private var title: String {
        let known = model.title(for: task.taskID)
        if !known.isEmpty { return known }
        if !task.taskTitle.isEmpty { return task.taskTitle }
        return "任务 \(task.taskID.prefix(8))"
    }

    /// 这一行的产物定位到哪一步了。**「在访达中显示」那颗按钮的亮/灰，和它下面
    /// 那行说明，都从这一个答案派生** —— 判据只此一份（见 `AppModel.OutputState`）。
    /// 以前两处各写各的，才凑得出「按钮灰着、旁边一句话都没有」的那种组合。
    private var outputState: AppModel.OutputState { model.outputState(task.taskID) }

    /// 失败归因：出错、且用的不是 WEB 接口。
    ///
    /// **这是事后归因，不是核心的原话。** 核心不把错误文本回给客户端
    /// （`TaskStatusReply` 里没有错误字段），能拿到的只有任务的 `api_type`。
    /// 所以措辞必须写成「实测这种现象对应的是 TV/APP」，不能写成断言。
    private var needsAPIAttribution: Bool {
        task.taskStatus == .taskError && task.apiType != .web
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

                // 「没配上标题」的标记必须**贴在这一行自己的标题旁边**：列表顶部
                // 那条说明只能报出「有几条」，用户对不上是哪几行。判据用模型里
                // 配对的结果（`isUnpaired`），不按标题的长相去猜 —— 「标题回退成
                // 任务 id」和「核心根本没回显名字」在行里长得一模一样，看图判会
                // 判错，而这两种情况确实是分开的（见 `AppModel.claimNewTasks`）。
                if model.isUnpaired(task.taskID) {
                    tag("没配上标题", tint: .secondary)
                }

                // 仅音频的任务要能一眼认出来：产物是 mp3 而不是 mp4，
                // 文件名和体积都对不上「视频」的预期。判据用任务回复里的
                // `audio_only`，那是核心回显的，可信。
                if task.audioOnly {
                    tag("仅音频", tint: .teal)
                }
                // WEB 是默认值，标出来只会刷屏；非 WEB 才标。
                if task.apiType != .web {
                    tag(task.apiType.label, tint: .orange)
                }

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

            if needsAPIAttribution {
                NoticeLine(symbol: "exclamationmark.triangle.fill", tint: .orange, text: """
                    这个任务用的是 \(task.apiType.label) 接口。实测核心在这种任务上取不到\
                    播放地址，核心日志里是 `API TV not allowed` / `API APP not allowed` \
                    这样的字样 —— 产出零字节、任务随即转「出错」。**换 WEB 重新提一次**\
                    就能下。

                    说明一下这条是怎么来的：核心不把错误文本回给客户端，所以这里是按任务\
                    的接口类型**事后归因** —— 用的是 WEB 的任务出错就不会显示这一行，\
                    那种情况的原因未知。
                    """)
            }

            // 这一行**不是**上面那条的 `else`：那条说的是「任务为什么出错」，
            // 这条说的是「这颗按钮为什么点不动」，两件事。串成 `else if` 的话，
            // 出错的任务只剩归因那一句，而它的文件夹按钮同样灰着 —— 旁边没有
            // 任何一句解释它，正是本轮要修掉的组合。
            //
            // 判据与按钮同源：`task.isFinished` 决定按钮给不给，`outputState`
            // 决定按钮亮不亮；这里把两个判据一起照搬过来，于是**只要按钮是灰的，
            // 下面那条说明就一定在**（反过来，说明在的时候按钮一定灰着 ——
            // 定位到了就没有这一行）。别退回在行里现算「完成超过 30 秒」：那是
            // 墙钟谓词，不依赖任何被观察的状态，只在别处字段变化引起重渲染时被
            // 顺带重算 —— 用户没做任何操作，这一行也会凭空变高（说明是两行），
            // 把下面的行整体顶下去，他正要点的那颗按钮就换成了别的（见
            // `AppModel.gaveUpTaskIDs`）。
            //
            // 写法上也别再说「App 重启过」：重启早就不影响定位了 —— 主干名取自
            // 核心回显的 `task_title`，App 一启动就能重新认回来（见
            // `AppModel.claimNewTasks`），跟内存里那张表在不在无关。
            if task.isFinished, outputState != .located {
                if outputState == .givenUp {
                    NoticeLine(symbol: "questionmark.folder", tint: .secondary, text: """
                        在下载目录里没找到这个任务的产物，所以「在访达中显示」是灰的。\
                        找的是「主干名 空格 (角标).扩展名」这种形状的文件，没找着。\
                        可能是核心中途出错、根本没落盘，也可能文件被改名、移动或删掉了。\
                        还有一种本项目没验证过的情况：核心实际落盘用的主干名和它回显的\
                        不一致 —— 不敢排除，所以如实列在这里。

                        模型已经不再给它找产物了，所以这一次运行里这颗按钮不会自己
                        亮起来；重开 App 会重新找一遍（那时文件在的话就会亮）。
                        """)
                } else {
                    // 还没判过的那一段（`isFinished` 刚成立、模型还没来得及扫目录，
                    // 或者没找到但离放弃还有 30 秒）。这里**不能说「没找到」** ——
                    // 模型还在每 2 秒比一次目录，说过头就成了没影的假话；但也不能
                    // 什么都不说：按钮这时同样是灰的，而这是用户唯一能看见的解释。
                    NoticeLine(symbol: "questionmark.folder", tint: .secondary, text: """
                        这个任务的产物还没在下载目录里认到，所以「在访达中显示」\
                        还是灰的。每 2 秒会拿「主干名 空格 (角标).扩展名」这种形状\
                        去比一次目录，认到就亮；核心收尾 30 秒后还没认到，就不再找了。
                        """)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// 任务行下面的一行说明。和 ParseView 的 `NoteBox` 是同一套样式，
/// 但那个是 private（跨文件用不了），这里按本文件的需要内联一份。
private struct NoticeLine: View {
    let symbol: String
    let tint: Color
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
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
                // 显示的是**这一行自己的**产物（`savedPath(for:)` 按任务 id 存），
                // 没定位到就点不动。禁用按钮的 tooltip 在 macOS 上多半不弹，所以
                // 「为什么点不动」还得靠行内那行说明，不能只写在 help 里 ——
                // 那行说明与这颗按钮的判据同源（`TaskRow.outputState`）：灰着就
                // 一定有一句，tooltip 说的也是同一件事，不给第三种说法。
                let state = model.outputState(task.taskID)
                iconButton("folder", Self.folderHelp(state)) {
                    model.reveal(taskID: task.taskID)
                }
                .disabled(state != .located)
            }
            iconButton("trash", "仅删除任务") { await model.control(task.taskID, .delete) }
            iconButton("trash.slash", "删除任务和文件") {
                await model.control(task.taskID, .deleteAndFile)
            }
        }
        .buttonStyle(.borderless)
    }

    /// 文件夹按钮的 tooltip。**和按钮的亮/灰、行内那行说明说的是同一件事**：
    /// 以前 tooltip 一律写「暂时点不动」，而模型其实早就放弃找了 —— 用户把鼠标
    /// 停上去（虽然多半不弹）看到的和界面上那句话说不到一块儿去。
    private static func folderHelp(_ state: AppModel.OutputState) -> String {
        switch state {
        case .located: "在访达中显示这个任务的产物"
        case .searching: "还没定位到这个任务的产物，暂时点不动（下面那行说明了原因）"
        case .givenUp: "没在下载目录里找到这个任务的产物，点不动（下面那行说明了原因）"
        }
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
