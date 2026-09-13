import JiJiKit
import JiJiProtos
import SwiftUI

struct ParseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        // 套一层滚动：分P 网格、接口警示、参数区加起来比一屏高，窗口压到最小
        // 尺寸时「开始下载」会被挤出去 —— 主操作按钮够不着是最难受的一种布局。
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    TextField("粘贴 B 站链接或 BV 号", text: $model.input)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.parse() } }

                    Button("解析") { Task { await model.parse() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.input.isEmpty || model.isParsing || !model.core.phase.isRunning)
                }

                if model.isParsing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("解析中…").foregroundStyle(.secondary)
                    }
                }

                if let error = model.parseError {
                    ErrorBox(text: error)
                }

                if let video = model.parsedVideo {
                    VideoCard(video: video)
                }

                if let info = model.parsedVideo, !info.block.isEmpty {
                    PagePicker(video: info)
                }

                if model.qualities == nil, model.parsedVideo != nil {
                    QualityUnavailableNote(error: model.qualitiesError)
                } else if let qualities = model.qualities {
                    QualitySummary(qualities: qualities)
                }

                if model.parsedVideo != nil {
                    DownloadOptions()
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 通用组件

/// 一段带图标的说明条。
///
/// `text` 的类型是 `LocalizedStringKey` 而不是 `String`：正文里有 `**强调**`，
/// 走 `Text(String)` 那个重载的话 markdown 不会被解析，界面上会原样显示星号。
private struct NoteBox: View {
    let icon: String
    let tint: Color
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 参数区里「小标题 + 控件」的一格。
private struct FieldBox<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

private struct ErrorBox: View {
    /// 错误正文来自 AppModel（`String`），里面的 `**` 得靠 `Markdown.inline`
    /// 才渲染得出来 —— 直接 `Text(text)` 只会显示星号。
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(Markdown.inline(text))
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct VideoCard: View {
    let video: Jijidown_Core_BvideoInfoReply

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let cover = NSImage(data: video.videoCover) {
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(16 / 10, contentMode: .fill)
                    .frame(width: 168, height: 105)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: 168, height: 105)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(video.displayTitle)
                    .font(.headline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if let up = NSImage(data: video.upFace) {
                        Image(nsImage: up).resizable().frame(width: 18, height: 18).clipShape(.circle)
                    }
                    Text(video.upName).font(.callout).foregroundStyle(.secondary)
                    if !video.sort.isEmpty {
                        Text(video.sort)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }

                if !video.videoDesc.isEmpty {
                    Text(video.videoDesc)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
    }
}

// MARK: - 分P 多选

/// 分P 多选。选中集合存在 AppModel 里（`selectedCids`）—— 不能用 @State。
///
/// cid 为 0 的分P 直接不显示：核心拿 cid 认视频，这种提不了任务。
///
/// 排版按数量分两档。横向胶囊条在分P 多时很难用：得来回拖着找，而且没有
/// 「一共有多少」的视觉边界。实测 100P 的视频在这条上表现最差，所以超过
/// `gridThreshold` 换成**定高的纵向网格** —— 纵向滚动有天然边界，也不会
/// 把下面的清晰度、下载参数顶出屏幕。
private struct PagePicker: View {
    @Environment(AppModel.self) private var model
    let video: Jijidown_Core_BvideoInfoReply

    /// 超过这个数就换纵向网格。
    private static let gridThreshold = 20

    var body: some View {
        let pages = video.allPages.filter { $0.pageCid != 0 }
        if pages.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                header(pages)
                if pages.count > Self.gridThreshold {
                    grid(pages)
                } else {
                    chipRow(pages)
                }
            }
        }
    }

    /// 「共 N / 已选 M」+ 三个批量勾选动作。
    ///
    /// 全选是**直接给集合赋值**，不是逐条 toggle —— 分P 上百时逐个调用会触发
    /// 上百次视图更新。
    private func header(_ pages: [Jijidown_Core_BvideoPage]) -> some View {
        HStack(spacing: 10) {
            Text("分P（共 \(pages.count)，已选 \(model.selectedPages.count)）")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // 选多了顺手提醒一句：选 100 个是要排到明天的。这个提醒只在量真的
            // 会上头时才出现，免得平时也占着一行。
            //
            // 归因要小心：「因为核心串行下载」只在 `maxTaskApplied == true` 时
            // 才成立（配置没写进去时核心可能并行跑）。不成立就只说「会排很久」，
            // 不带这个原因 —— 否则就是同一句假保证换了个地方讲。
            if model.selectedPages.count > 10 {
                Text(model.core.maxTaskApplied == true
                     ? "核心串行下载，选这么多会排很久"
                     : "选这么多要排很久")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button("全选") { model.selectedCids = Set(pages.map(\.pageCid)) }
            Button("反选") {
                model.selectedCids = Set(pages.map(\.pageCid)).subtracting(model.selectedCids)
            }
            Button("清空") { model.selectedCids = [] }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
    }

    private func chipRow(_ pages: [Jijidown_Core_BvideoPage]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(pages, id: \.pageCid) { page in
                    PageChip(page: page, active: model.isSelected(page)) {
                        model.togglePage(page)
                    }
                }
            }
        }
    }

    private func grid(_ pages: [Jijidown_Core_BvideoPage]) -> some View {
        ScrollView(.vertical) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(pages, id: \.pageCid) { page in
                    PageChip(page: page, active: model.isSelected(page), fillsWidth: true) {
                        model.togglePage(page)
                    }
                }
            }
            .padding(.trailing, 4)
        }
        .frame(height: 156)
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 一个分P 的勾选块。
///
/// 选中态**不只靠颜色**：22% 的色调差在色觉障碍下很难分辨，所以再挂一个对勾
/// 和一圈描边。两个形状信号在，去掉颜色也读得出来。
private struct PageChip: View {
    let page: Jijidown_Core_BvideoPage
    let active: Bool
    /// 网格里让每格填满列宽；横向胶囊条里按内容宽度，否则会把滚动条撑到无限宽。
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        let maxWidth: CGFloat? = fillsWidth ? .infinity : nil

        Button(action: action) {
            HStack(spacing: 5) {
                // 对勾始终占位（取消选中时是透明的），否则文字会左右横跳。
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .opacity(active ? 1 : 0)

                Text("P\(page.pageIndex) \(page.pageTitle)")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(
                active ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                       : AnyShapeStyle(.quaternary),
                in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear),
                    lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .help("P\(page.pageIndex) \(page.pageTitle)")
    }
}

// MARK: - 可用清晰度

private struct QualitySummary: View {
    let qualities: Jijidown_Core_BvideoAllQualityReply

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("可用清晰度").font(.subheadline).foregroundStyle(.secondary)

            // 这份列表是解析时按第一个分P 查的，勾选变了也不会重查。
            Text("这份列表是解析时按第一个分P（默认选中的那个）查的，之后改勾选不会重新查 —— 但选档位不依赖它，`video_quality` 是直接发给核心的。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if qualities.video.isEmpty && qualities.audio.isEmpty {
                Text("核心没有返回任何可下载的流。")
                    .font(.callout).foregroundStyle(.tertiary)
            }

            ForEach(Array(qualities.video.enumerated()), id: \.offset) { _, v in
                HStack(spacing: 8) {
                    Text(v.qualityText).font(.callout)
                    Text(v.codec.label)
                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if !v.frameRate.isEmpty {
                        Text(v.frameRate).font(.caption).foregroundStyle(.secondary)
                    }
                    if !v.bitRate.isEmpty {
                        Text(v.bitRate).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Fmt.orDash(v.streamSize)).font(.caption).foregroundStyle(.secondary)
                    Text(v.apiType.label)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            if !qualities.audio.isEmpty {
                Text("音频").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                ForEach(Array(qualities.audio.enumerated()), id: \.offset) { _, a in
                    HStack(spacing: 8) {
                        Text(a.qualityText).font(.callout)
                        Text(a.codecText).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.orDash(a.streamSize)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 清晰度枚举拿不到时的说明。
///
/// 这段说明**必须按成因分叉，不能写死成一句话**。`qualities == nil` 罩着两种
/// 完全不同的来源（判据见 `AppModel.qualitiesError`）：
///
/// - `AllQuality` 发出去了但失败 —— `error` 就是核心原样给的那条。可能是一次
///   超时（核心刚起来、本机网络抖动），也可能是核心的会员门；
/// - `AllQuality` **一次都没被调用**（`error` 为 nil）—— 视频的分P 里没有
///   `cid` 非 0 的条目，`AppModel.parse` 里那个 `if let` 整个没进去。
///
/// 以前这里只有一句写死的话，把两种情形一起说成「核心的会员门，不是网络问题，
/// 重试也没用」。用户据此认定自己的账号没有唧唧会员、再试也没意义，而真实原因
/// 可能只是那一次请求超时 —— 界面把一次超时说成了「你的账号不行」。
///
/// 第二段（为什么下面那个档位下拉照样能用）三种情形都一样，所以只写一次：
/// 档位和这份列表本来就是两条独立的路，别让人以为档位是从列表里来的。
private struct QualityUnavailableNote: View {
    /// 取列表失败的原因。**nil 表示「没查过」**，不是「查成功了」——
    /// 成功时 `qualities` 就不是 nil，这段说明根本不会出现。
    let error: CoreError?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            // 正文是拼出来的变量，得走 `Markdown.inline` 才认 `**` 与反引号
            // （`Text(String)` 那个重载不解析 markdown，会原样显示星号）。
            Text(Markdown.inline(cause + allCasesTail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 第一段：没拿到列表的原因。
    private var cause: String {
        guard let error else {
            return """
                没查过清晰度列表 —— 核心这次返回的分P 里**没有 `cid` 非 0 的条目**，\
                客户端是按第一个这种分P 去查的，所以 `AllQuality` 一次都没发出去。\
                这个视频多半没有可下载的分P，下面也就没有分P 能勾选。
                """
        }

        switch error {
        case .premiumFeature(let message):
            return """
                拿不到清晰度列表 —— 核心对 `AllQuality` 的原话是 `\(message)`。\
                这是核心自己的一道门，与网络无关；账号和授权状态没变的话，\
                重试同一条请求结果不会变。

                至于这道门挡的是「你的账号没有唧唧会员」还是「核心这个版本还没开放\
                它」，**本项目没有实测依据**：厂商客户端把它记作「无唧唧会员权限」，\
                官网又写着唧唧终身免费，两种说法对不上，所以这里只把核心的原话摆出来，\
                不替它下结论。
                """

        case .coreNotRunning:
            return """
                拿不到清晰度列表 —— 核心没在运行（`AllQuality` 那条请求连不上）。\
                去「核心」页把它起起来，再解析一次。
                """

        default:
            // `guidance` 在 `.rpc` 这一支跟 `description` 是同一句话，贴两遍会
            // 让人以为一次出了两个错。
            let advice = error.guidance == error.description ? "" : "\n\n\(error.guidance)"
            return """
                拿不到清晰度列表 —— 核心回的是 `\(error.description)`。\
                这**未必是稳定的**：核心刚起来、或本机网络抖动时，这一次查询会超时。\
                可以再试一次；再不行就看下面这句。\(advice)
                """
        }
    }

    /// 第二段：列表拿不到不影响什么。
    private var allCasesTail: String {
        """


        好在选档位不依赖它：下面按 B 站标准清晰度直接选，`video_quality` \
        是原样发给核心的。选了该视频没有的档位，核心会报错，换个档位即可。
        """
    }
}

// MARK: - 下载参数

/// 下载参数 + 开始按钮。下的是 `selectedPages` 里全部选中的分P。
private struct DownloadOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let count = model.selectedPages.count

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 16) {
                // 仅音频时这两项降饱和。**不禁用、不隐藏**：核心在 audio_only 下
                // 是否还会校验清晰度与编码，本项目没实测过；而编码一旦传 UNKNOWN
                // 核心会 panic 退出，这个必填约束不能在界面上消失。降饱和是为了
                // 表达「它可能不参与」，不是把它关掉。
                HStack(alignment: .bottom, spacing: 16) {
                    FieldBox("清晰度") {
                        Picker("", selection: $model.quality) {
                            ForEach(VideoQuality.allCases) { q in
                                Text(q.label).tag(q)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }

                    FieldBox("编码") {
                        Picker("", selection: $model.codec) {
                            Text("AVC / H.264").tag(Jijidown_Core_VideoType.avc)
                            Text("HEVC / H.265").tag(Jijidown_Core_VideoType.hevc)
                            Text("AV1").tag(Jijidown_Core_VideoType.av1)
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
                .saturation(model.audioOnly ? 0.2 : 1)
                .opacity(model.audioOnly ? 0.7 : 1)

                FieldBox("音质") {
                    Picker("", selection: $model.audio) {
                        ForEach(AudioQuality.allCases) { a in
                            Text(a.label).tag(a)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                FieldBox("接口") {
                    Picker("", selection: $model.downloadAPI) {
                        ForEach(DownloadAPI.allCases) { a in
                            Text(a.label).tag(a)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                Spacer()
            }

            Toggle("仅下载音频（产物是 mp3，没有视频轨）", isOn: $model.audioOnly)
                .toggleStyle(.checkbox)
                .font(.callout)

            if model.audioOnly {
                NoteBox(icon: "speaker.wave.2", tint: .secondary, text: """
                    上面清晰度与编码两项**可能不参与**：核心在「仅下载音频」下还会不会\
                    校验它们，本项目没有实测。所以这里只是降饱和，没有禁用也没有隐藏 ——\
                    编码不能选 UNKNOWN（传给它核心会直接崩溃退出），这个约束得一直在。
                    """)
            }

            if model.downloadAPI != .web {
                // 警示就在选择当下出现，不折进「详情」里：这是唯一能预防的时机，
                // 藏起来等于等用户踩了坑再说。
                NoteBox(icon: "exclamationmark.triangle.fill", tint: .orange, text: """
                    接口选的是 \(model.downloadAPI.label)：**实测这条现在下不了**。\
                    核心会照常接受任务，但到取播放地址那一步会失败，核心日志里是 \
                    `API TV not allowed` / `API APP not allowed` 这样的字样 ——\
                    产出零字节，任务随即转「出错」，换回 WEB 重新提一次就行。

                    原因还没查到底，两个候选：核心的授权位没给这个接口放行；或者还得\
                    再配一个 raw-access-token（「账号」页那个 AccessToken 输入就是喂\
                    它的位置）。两条都没验完，所以这里只说「目前下不了」，不解释成因。
                    """)
            }

            // 判据从 `VideoQuality.requiresHEVC` 取，别在这里就地重写一遍
            // 「== .dolbyVision」：同一个事实写两处，哪天多一个也只认 HEVC 的
            // 清晰度，改了一处忘了另一处，提示就静默失效。
            if model.quality.requiresHEVC, model.codec != .hevc {
                NoteBox(icon: "exclamationmark.triangle", tint: .orange, text: """
                    杜比视界只在 HEVC 编码下存在，现在选的是 \(model.codec.label)，\
                    很可能拿不到流。
                    """)
            }

            HStack(alignment: .center, spacing: 12) {
                Text(serialNote(count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Button {
                    Task { await model.enqueue(pages: model.selectedPages) }
                } label: {
                    Label(
                        count > 1 ? "开始下载 \(count) 个" : "开始下载",
                        systemImage: "arrow.down.circle.fill"
                    )
                }
                .keyboardShortcut(.defaultAction)
                // `isEnqueuing` 也得上：这个按钮绑了 `.defaultAction`，回车就能
                // 触发，连按两下会发两次 `enqueue`。真正的兜底在 `enqueue` 入口
                // 那道闸（这里置位要等一次主 actor 轮转，挡不住紧挨着的那一下），
                // 按钮禁用只是为了别让第二次点击落进「点了没反应」的空档。
                .disabled(count == 0 || model.isEnqueuing)
            }
        }
    }

    /// 批量下载最需要的一句预期管理：核心会不会同时跑这 N 个任务。
    ///
    /// **「串行」不是无条件成立的事实**，它取决于 config.yaml 里的 `max-task`。
    /// 而本客户端的 `writeConfig` 有一条早退分支：config.yaml 已存在、又没有
    /// `.managed-by-client` 旁路标记时，一个字都不写，`max-task: 1` 不落地 ——
    /// 后果只写在核心日志里，用户看不到。承诺之前先看 `maxTaskApplied`：
    /// 落地了才说串行，没落地就直说没落地，并且要把「可能互相覆盖」这层讲出来
    /// （核心撞名是静默覆盖的，那道防线整个在客户端）。核心实际的并行度是多少
    /// 本项目**没实测**，所以这里只说「可能并行」，不替它报数字。
    private func serialNote(_ count: Int) -> String {
        if count == 0 { return "还没勾选分P —— 在上面挑一个。" }

        switch model.core.maxTaskApplied {
        case true:
            // 本次写进配置的是 max-task: 1，这个说法是确定的。
            guard count > 1 else {
                return "核心是串行下载（本次已写配置 max-task: 1），一次只跑一个任务。"
            }
            return """
                核心是串行下载（本次已写配置 max-task: 1）：这 \(count) 个分P 会一个个依次进行，\
                不会同时跑，也不会一起下完 —— 排在后面的要等前面的做完。
                """

        case false:
            // 这行 Text 收的是 String，不是 LocalizedStringKey，所以**不能用
            // `**粗体**`** —— 原样打出来。要点靠措辞和破折号顶。
            let how = "要让本客户端接管这份配置：退出后把 \(CoreManager.managedMarker.path) 建成一个空文件，再启动核心。"
            guard count > 1 else {
                return """
                    这一次没有写 config.yaml（它已存在、又没有本客户端的标记，按用户手写的配置处理），\
                    max-task: 1 没落地 —— 核心是不是一次只跑一个任务，取决于它自己那份配置里的并行度，\
                    这个数本项目没实测，这里不下结论。\(how)
                    """
            }
            return """
                这一次没有写 config.yaml（它已存在、又没有本客户端的标记，按用户手写的配置处理），\
                max-task: 1 没落地：这 \(count) 个分P 仍会逐个提交，但核心可能并行下载，\
                多个产物同时往同一个目录里落 —— 核心撞名是静默覆盖的，本客户端那道避让账\
                （按已经落盘的主干算）就可能算漏，撞上的文件会被直接覆盖。\(how)
                """
        default:
            // 本次还没写过配置（核心没起来过）：这时候什么都别说死。
            guard count > 1 else {
                return "核心还没起来，本次也没写过配置 —— 它会不会一次只跑一个任务，这里不确定。"
            }
            return """
                核心还没起来，本次也没写过配置：这 \(count) 个分P 会逐个提交，但核心会不会并行下载\
                取决于它自己那份配置，这里不确定。
                """
        }
    }
}
