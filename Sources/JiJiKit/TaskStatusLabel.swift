import JiJiProtos

/// 任务状态的中文名。
///
/// 放在协议层而不是 UI 层：命令行工具也要用，而且它本来就跟 UI 无关。
///
/// 关于 `UNRECOGNIZED`：核心比公开的 proto 新（实测 `ServerIconType` 已经
/// 返回到 26，而 proto 里最大是 21），所以**必须**处理未知枚举值 ——
/// 直接 `switch` 穷举而漏掉它，遇到新状态就会崩。
///
/// 两件实测记下的事（r339）：
///
/// 1. **同一个 0 在两个位置含义不同。** 当**过滤条件**（`Task.List` 的
///    `task_status`）时它是「不过滤」，列的是全部任务；当**任务自己的
///    `taskStatus`** 时它才是「出错」。名字只有 `.taskError` 一个，
///    所以看到它先看是哪个位置 —— 详见 `CoreClient.listTasks`。
/// 2. **6（`taskComplete`）从未出现过。** 任务干完停在 5（见
///    `TaskStatusReply.isFinished` 的说明），所以枚举里的名字不能当判据用。
extension Jijidown_Core_TaskStatusType {
    public var label: String {
        switch self {
        case .taskError: "出错"
        case .taskPause: "已暂停"
        case .taskRunning: "下载中"
        case .taskWait: "等待中"
        case .taskMergeing: "合并中"
        case .taskGenmusic: "提取音频"
        case .taskComplete: "已完成"
        case .UNRECOGNIZED(let raw): "未知状态(\(raw))"
        }
    }
}

extension Jijidown_Core_TaskStatusReply {
    /// 任务是否真的干完了。
    ///
    /// **不能只看 `taskStatus`。** 实测（r339）：下载全部结束后，状态**停在
    /// `TASK_GENMUSIC(5)`，并不会翻到 `TASK_COMPLETE(6)`** —— 而 5 同时又是
    /// 「正在提取 MP3」这个进行中的状态，光看枚举分不出「在干活」和「干完了」。
    ///
    /// `completeTime` 才是可靠信号：核心只在收尾时填它。
    ///
    /// **注意判据是 `> 0` 不是 `!= 0`。** 任务没完成时，核心给的不是 0，而是
    /// `-62135596800` —— 那是 Go 的零值 `time.Time`（公元 1 年 1 月 1 日）
    /// 对应的 Unix 秒数。写成 `!= 0` 的话每个任务一建出来就被判成已完成，
    /// 会立刻触发改名和「已完成」状态。
    ///
    /// **终态判据只有这一个（`completeTime > 0`），不要改按枚举判。** 曾经有过
    /// 一个 `isTerminal`（`taskComplete || taskError`），已删 —— 实测终态 5
    /// （`TASK_GENMUSIC`，见上面那条）在它眼里「不是终态」，而 6 从未出现过，
    /// 拿它判就等于任务永远完不成。
    public var isFinished: Bool { completeTime > 0 }

    /// 给人看的状态文字。已完成的按「已完成」显示，不要照着枚举念成「提取音频」。
    public var displayLabel: String {
        isFinished ? "已完成" : taskStatus.label
    }
}
