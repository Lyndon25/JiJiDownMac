import JiJiProtos

/// 任务状态的中文名。
///
/// 放在协议层而不是 UI 层：命令行工具也要用，而且它本来就跟 UI 无关。
///
/// 关于 `UNRECOGNIZED`：核心比公开的 proto 新（实测 `ServerIconType` 已经
/// 返回到 26，而 proto 里最大是 21），所以**必须**处理未知枚举值 ——
/// 直接 `switch` 穷举而漏掉它，遇到新状态就会崩。
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

    /// 是否已到终态（不会再变化）。
    public var isTerminal: Bool {
        self == .taskComplete || self == .taskError
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
    public var isFinished: Bool { completeTime > 0 }

    /// 给人看的状态文字。已完成的按「已完成」显示，不要照着枚举念成「提取音频」。
    public var displayLabel: String {
        isFinished ? "已完成" : taskStatus.label
    }

    /// 核心给这个任务的产物起的文件名。
    ///
    /// 直接用任务回复里自带的角标字段拼 —— 这几个字符串正是核心命名时用的那几段，
    /// 所以能拼得一模一样，不必自己去复刻核心的「清晰度 id → 中文角标」映射表。
    public var coreOutputName: String {
        OutputNaming.coreName(
            videoBadge: videoBadge,
            codec: videoCodec,
            audioBadge: audioBadge,
            api: apiType.label
        )
    }
}
