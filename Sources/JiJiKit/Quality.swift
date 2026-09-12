import JiJiProtos

/// B 站视频清晰度 id。
///
/// ## 为什么是硬编码的一串常量
///
/// 核心本该有 `Bvideo.AllQuality` 用来枚举某个视频真正可用的清晰度，但
/// **那个接口是唧唧会员付费功能**：
///
///     Bvideo.AllQuality → ABORTED: AllQuality It's a premium feature
///
/// 所以非会员客户端只能按标准 id 去试。好消息是「试错」很安全：只要
/// `video_codec` 是合法值，清晰度不存在时核心只会干净地报
/// `expected video quality 'X', got 'Y'`，不会崩。
///
/// ⚠️ 但 `video_codec` **绝不能传 UNKNOWN(0)** —— 实测核心会按编码过滤，
/// 0 匹配不到任何流，拿到空列表后在 `jdm.NewSession` 里 `index out of range`
/// 直接 panic 退出。
public enum VideoQuality: UInt32, CaseIterable, Identifiable, Sendable {
    case q8K = 127
    case dolbyVision = 126
    case hdr = 125
    case q4K = 120
    case p1080_60 = 116
    case p1080Plus = 112
    case p1080 = 80
    case p720_60 = 74
    case p720 = 64
    case p480 = 32
    case p360 = 16

    public var id: UInt32 { rawValue }

    public var label: String {
        switch self {
        case .q8K: "8K 超高清"
        case .dolbyVision: "杜比视界"
        case .hdr: "HDR 真彩"
        case .q4K: "4K 超清"
        case .p1080_60: "1080P60 高帧率"
        case .p1080Plus: "1080P+ 高码率"
        case .p1080: "1080P 高清"
        case .p720_60: "720P60 高帧率"
        case .p720: "720P 高清"
        case .p480: "480P 清晰"
        case .p360: "360P 流畅"
        }
    }

    /// 杜比视界只在 HEVC 下存在。
    public var requiresHEVC: Bool { self == .dolbyVision }

    /// 从高到低的常用降级顺序，用于「按优先级尝试」。
    public static let fallbackLadder: [VideoQuality] = [
        .dolbyVision, .q4K, .p1080_60, .p1080Plus, .p1080, .p720, .p480, .p360,
    ]
}

/// B 站音频音质 id。
public enum AudioQuality: UInt32, CaseIterable, Identifiable, Sendable {
    case hiRes = 30251
    case dolbyAtmos = 30250
    case q192K = 30280
    case q132K = 30232
    case q64K = 30216

    public var id: UInt32 { rawValue }

    public var label: String {
        switch self {
        case .hiRes: "Hi-Res 无损"
        case .dolbyAtmos: "杜比全景声"
        case .q192K: "192K"
        case .q132K: "132K"
        case .q64K: "64K"
        }
    }
}

/// 下载接口。实测 **TV 与 APP 都是会员功能**：
///
///     [playurl] API TV not allowed
///     [playurl] API APP not allowed
///
/// 所以非会员只能用 WEB。
public enum DownloadAPI: UInt32, CaseIterable, Identifiable, Sendable {
    case web = 0
    case tv = 1
    case app = 2

    public var id: UInt32 { rawValue }
    public var label: String {
        switch self {
        case .web: "WEB"
        case .tv: "TV（会员）"
        case .app: "APP（会员）"
        }
    }
}
