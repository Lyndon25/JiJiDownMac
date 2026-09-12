import JiJiKit
import JiJiProtos
import SwiftUI

// MARK: - 任务状态

extension Jijidown_Core_TaskStatusType {
    // `label` / `isTerminal` 定义在 JiJiKit（协议层），命令行工具也要用。

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

// MARK: - 清晰度 / 编码

// `VideoType` / `ApiType` 的 `label` 定义在 JiJiKit（协议层）：
// 核心拼产物文件名时用的就是 `ApiType` 的字符串形式，协议层必须能拿到。

// MARK: - 格式化

enum Fmt {
    /// 时长秒数 → mm:ss / h:mm:ss
    static func duration(_ seconds: Int64) -> String {
        guard seconds > 0 else { return "--:--" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// 核心返回的是带单位的字符串（如 "15.92 MiB"），原样透传即可，
    /// 但空值要有个体面的占位。
    static func orDash(_ text: String) -> String {
        text.isEmpty ? "—" : text
    }
}
