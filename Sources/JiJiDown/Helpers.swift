import JiJiKit
import JiJiProtos
import SwiftUI

// MARK: - 任务状态

extension Jijidown_Core_TaskStatusType {
    // 状态的中文名（`label`）定义在 JiJiKit（协议层），命令行工具也要用；
    // 这里只补 SwiftUI 的颜色。

    var tint: Color {
        switch self {
        case .taskError: .red
        case .taskPause: .secondary
        case .taskRunning: .accentColor
        case .taskWait: .orange
        case .taskMergeing, .taskGenmusic: .purple
        case .taskComplete: .green
        case .UNRECOGNIZED: .secondary
        }
    }
}

extension Jijidown_Core_TaskStatusReply {
    /// 已完成的任务在核心那边状态停在 `GENMUSIC`，颜色得跟着改过来，
    /// 否则一个已经下完的任务会顶着紫色的「提取音频」样式。
    var tint: Color { isFinished ? .green : taskStatus.tint }
}

// MARK: - 核心状态

extension CoreManager.Phase {
    var label: String {
        switch self {
        case .idle: "未启动"
        case .preparing(let what): what
        case .starting: "启动中"
        case .running: "运行中"
        case .stopped: "已停止"
        case .failed(let why): why
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .failed: .red
        case .idle, .stopped: .secondary
        case .preparing, .starting: .orange
        }
    }
}

// MARK: - 检查更新

extension Jijidown_Core_UpdateStatusType {
    /// 检查更新结果的颜色。
    ///
    /// 只有 `needupdate` 用醒目的橙色：它是唯一一条「值得让用户立刻看见」的
    /// 结论（状态栏角标也只在它上面出现）。其余几档一律二级色 ——
    /// 常驻的彩色标记会退化成噪音，用户很快就学会无视它。
    var tint: Color {
        switch self {
        case .checking: .secondary
        case .notsupportupdate: .secondary
        case .uptodate: .green
        case .needupdate: .orange
        case .UNRECOGNIZED: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .checking: "clock"
        case .notsupportupdate: "info.circle"
        case .uptodate: "checkmark.seal"
        case .needupdate: "arrow.down.circle.fill"
        case .UNRECOGNIZED: "questionmark.circle"
        }
    }
}

// MARK: - 清晰度 / 编码

// `VideoType` / `ApiType` 的 `label` 定义在 JiJiKit（协议层）：
// 核心拼产物文件名时用的就是 `ApiType` 的字符串形式，协议层必须能拿到。

// MARK: - Markdown

enum Markdown {
    /// 把 `**强调**` 这类**行内** markdown 渲染出来。
    ///
    /// 为什么需要这一层：`Text(某个 String 变量)` 走的是 `Text<S: StringProtocol>`
    /// 重载，**不解析 markdown** —— AppModel 里那些 `**…**` 会原样显示成一串星号。
    /// 只有字符串字面量（`LocalizedStringKey`）才会被解析，而错误文本是变量。
    ///
    /// `inlineOnlyPreservingWhitespace`：只认行内语法，且保留换行。用默认选项
    /// 会把多行错误文本重新折成一段。
    ///
    /// 解析失败（文本里有落单的 `*` 之类）就原样返回 —— 绝不能因为排版问题
    /// 把正文吃掉。
    static func inline(_ raw: String) -> AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(raw)
    }
}

// MARK: - 格式化

enum Fmt {
    /// 核心返回的是带单位的字符串（如 "15.92 MiB"），原样透传即可，
    /// 但空值要有个体面的占位。
    static func orDash(_ text: String) -> String {
        text.isEmpty ? "—" : text
    }
}
