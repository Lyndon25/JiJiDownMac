import JiJiProtos

/// 枚举的中文名。
///
/// 放在协议层而不是 UI 层：命令行工具要用，而且**核心拼文件名时用的就是
/// `ApiType` 的字符串形式**（`WEB` / `TV` / `APP`），协议层必须能拿到。
extension Jijidown_Core_ApiType {
    public var label: String {
        switch self {
        case .web: "WEB"
        case .tv: "TV"
        case .app: "APP"
        case .UNRECOGNIZED(let n): "未知(\(n))"
        }
    }
}

/// 检查更新状态的中文名。
///
/// 和 `TaskStatusType.label` 同理必须处理 `UNRECOGNIZED`：核心比公开的 proto 新，
/// 未知枚举值直接 switch 穷举会崩。
extension Jijidown_Core_UpdateStatusType {
    public var label: String {
        switch self {
        case .checking: "检查中 / 下载更新"
        case .notsupportupdate: "不支持自动更新"
        case .uptodate: "已是最新版本"
        case .needupdate: "需要更新"
        case .UNRECOGNIZED(let n): "未知(\(n))"
        }
    }
}

extension Jijidown_Core_VideoType {
    public var label: String {
        switch self {
        case .unknown: "未知"
        case .avc: "AVC/H.264"
        case .hevc: "HEVC/H.265"
        case .av1: "AV1"
        case .UNRECOGNIZED(let n): "未知(\(n))"
        }
    }
}
