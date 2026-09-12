import Foundation
import JiJiProtos

extension Jijidown_Core_BvideoInfoReply {

    /// 视频标题。
    ///
    /// 优先用 `meta.title` —— 它是 B 站那边的正式标题，比分P标题干净。
    /// 分P标题常常带着 UP 主自己加的前后缀（实测有个视频叫
    /// `ver2_0-2026.3 李现x人生第一座雪山Bili内嵌字幕ver4.0`，而
    /// `meta.title` 是 `和李现，攀登人生第一座雪山`）。
    ///
    /// 旧版本没有 `meta` 可用（上游 proto 把字段 2 标成了封面），只能拿分P
    /// 标题顶着，所以这里保留了那条回退路径。
    public var displayTitle: String {
        if !meta.title.isEmpty { return meta.title }
        if let page = block.first?.list.first, !page.pageTitle.isEmpty {
            return page.pageTitle
        }
        if let blockTitle = block.first?.blockTitle, !blockTitle.isEmpty {
            return blockTitle
        }
        return blinkResult.mark
    }

    // MARK: 元信息
    //
    // 这些以前是顶层字段，现在都住在 `meta` 里。留一层同名访问器，
    // 调用点就不必到处写 `meta.`，字段再搬家也只改这一处。

    /// 视频封面（JPEG 字节）。直接喂 `NSImage(data:)`。
    public var videoCover: Data { meta.cover }
    /// UP主昵称。
    public var upName: String { meta.upName }
    /// UP主头像（JPEG 字节）。
    public var upFace: Data { meta.upFace }
    /// UP主 mid。
    public var upMid: Int64 { meta.upMid }
    /// 视频简介。
    public var videoDesc: String { meta.desc }
    /// 分区，如「其他」。
    public var sort: String { meta.category }
    /// 发布时间，形如 `2026-04-16 12:00:00`。
    public var pubDate: String { meta.pubDate }

    /// 所有分P（跨块展平）。
    public var allPages: [Jijidown_Core_BvideoPage] {
        block.flatMap(\.list)
    }
}

extension Jijidown_Core_BvideoPage {
    /// 发布日期。
    ///
    /// 上游 proto 把字段 7 声明为 `repeated string page_info`，实测核心在那里
    /// 发的是发布日期文本；时长在字段 8，上游漏了，已补进 proto。
    public var publishDate: String {
        pageInfo.first ?? ""
    }
}
