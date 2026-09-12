import JiJiProtos

extension Jijidown_Core_BvideoInfoReply {

    /// 视频标题。
    ///
    /// 核心的 `BvideoInfoReply` **没有顶层标题字段** —— 上游公开 proto 把
    /// 字段 3 标成 `string video_title`，但核心实际在那儿放的是视频块
    /// （详见 `bvideo.proto` 里的说明）。所以标题要从分P或块标题里取。
    public var displayTitle: String {
        if let page = block.first?.list.first, !page.pageTitle.isEmpty {
            return page.pageTitle
        }
        if let blockTitle = block.first?.blockTitle, !blockTitle.isEmpty {
            return blockTitle
        }
        return blinkResult.mark
    }

    /// 所有分P（跨块展平）。
    public var allPages: [Jijidown_Core_BvideoPage] {
        block.flatMap(\.list)
    }
}

extension Jijidown_Core_BvideoPage {
    /// 时长等附加信息。
    ///
    /// 上游 proto 把字段 7 声明为 `repeated string page_info`，但核心实际
    /// 发的是两个独立字符串：字段 7 是发布日期、字段 8 是时长。字段 8 在
    /// 我们的 proto 里没有对应项，会被当作未知字段丢弃 —— 要拿到时长就得
    /// 补上它。
    public var publishDate: String {
        pageInfo.first ?? ""
    }
}
