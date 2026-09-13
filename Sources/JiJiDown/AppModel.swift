import AppKit
import Foundation
import JiJiKit
import JiJiProtos
import Observation
import SwiftUI

/// 主标签页。
enum MainTab: String, CaseIterable, Identifiable {
    case parse = "下载"
    case tasks = "任务"
    case account = "账号"
    case core = "核心"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .parse: "plus.rectangle.on.folder"
        case .tasks: "list.bullet.rectangle"
        case .account: "person.crop.circle"
        case .core: "gearshape.2"
        }
    }

    /// 读 `JJD_TAB` 环境变量决定启动页，认不出就用默认的「下载」。
    static var fromEnvironment: MainTab {
        guard let raw = ProcessInfo.processInfo.environment["JJD_TAB"],
              let tab = MainTab(rawValue: raw)
        else { return .parse }
        return tab
    }
}

/// 登录方式。核心只支持这两种 —— 没有短信、密码登录。
enum LoginMethod: String, CaseIterable, Identifiable {
    case qr = "扫码登录"
    case cookie = "Cookie 导入"
    var id: String { rawValue }
}

/// App 的单一状态源。
///
/// ## 为什么视图局部状态也混在这里
///
/// 本机没有 Xcode，而新版 SDK 把 SwiftUI 的 `@State` 实现成了宏
/// （`@externalMacro(module: "SwiftUIMacros", type: "StateMacro")`），
/// 该插件随 Xcode 分发，CLT 里没有 —— 所以 `@State` 一律编译不过。
///
/// `@Observable`（Observation 那套，插件在 CLT 里有）、`@StateObject`、
/// `@Environment(Type.self)`、`@Bindable` 都还能用。于是 App 级模型走静态
/// 单例，视图局部状态统一收到这里，视图用 `@Bindable` 取 Binding。
///
/// ## 哪些状态是「App 一退就没」的
///
/// 下面这些表都只活在内存里，进程一结束就没了，而任务与产物是**留在磁盘上**的：
/// `taskTitles` / `taskStems` / `pendingTitles` / `reservedStems` / `savedPaths`。
/// 代价说清楚：
///
/// - **提交时那个标题回不来。** 重开 App 后 `taskTitles` 是空的，旧任务在标题
///   对照表里配不上对，那些行显示的是核心回显的 `task_title`（那还是准确的，
///   就是文件主干名），并带上「没配上标题」的标记。
/// - **产物仍然认得回来** —— 定位不依赖上面这几张表：`claimNewTasks` 会把核心
///   回显的 `task_title` 当主干名重新记进 `taskStems`（**配不上对的也照记**），
///   `collectFinishedOutputs` 再拿它去下载目录里比对。前提是两个：核心仍然回显着
///   这条 `task_title`，并且文件还在下载目录里、名字仍是「主干名 (角标).扩展名」
///   那个形状 —— 缺一个就认不回来，那一行会显示「没找到产物」的说明。
/// - `reservedStems` 清空不影响防覆盖：真正兜底的是目录里已经存在的文件名，
///   它每次提交前都重读。
/// - 想把这些落盘（写进 Application Support 之类）得先想清楚「任务与文件的
///   对应关系凭什么在重启后还成立」，那是另一件事，本次不做。
@MainActor
@Observable
final class AppModel {

    static let shared = AppModel()

    // MARK: 界面状态（本该是视图局部的 @State，见上面的说明）

    var tab: MainTab = MainTab.fromEnvironment

    /// 选中的分P，按 cid 记。
    ///
    /// 为什么不是 `selectedPage: BvideoPage?`：一次要能下多个分P。为什么用
    /// cid 而不是装 `[BvideoPage]`：`BvideoPage` 是 protobuf 生成的 struct，
    /// **没有 Hashable**，进不了 `Set`；而 cid 是核心认分P 的唯一标识，
    /// 标题会变、cid 不会。
    var selectedCids: Set<Int64> = []

    /// 当前选中的分P，**按视频里分P 的顺序**排好。
    ///
    /// 顺序是有意义的：提交顺序就是这里的顺序，也就是界面上的顺序。
    /// 不能直接遍历 `selectedCids`（`Set` 的遍历顺序是随机的）。
    /// cid 为 0 的分P 一律跳过 —— 核心拿 cid 认视频，0 提交过去没有意义。
    var selectedPages: [Jijidown_Core_BvideoPage] {
        guard let video = parsedVideo else { return [] }
        return video.allPages.filter { $0.pageCid != 0 && selectedCids.contains($0.pageCid) }
    }

    func isSelected(_ page: Jijidown_Core_BvideoPage) -> Bool {
        selectedCids.contains(page.pageCid)
    }

    func togglePage(_ page: Jijidown_Core_BvideoPage) {
        guard page.pageCid != 0 else { return }
        if selectedCids.contains(page.pageCid) {
            selectedCids.remove(page.pageCid)
        } else {
            selectedCids.insert(page.pageCid)
        }
    }

    /// 只下音频。产物是 mp3（实测 253,067 字节、无视频轨），且任务回复里的
    /// `audio_only` 会回显 true，可作判据。
    var audioOnly = false
    var autoScroll = true

    // 下载参数。默认 1080P / HEVC / WEB —— 这三个是实测最稳的组合。
    //
    // 切换视频（重新解析）**不动这几个值**：用户挑过一次档位，下一条链接多半
    // 还要用同一档，每次解析都重置回默认只会让人重挑。`downloadAPI` 同理。
    var quality: VideoQuality = .p1080
    var audio: AudioQuality = .q192K
    var codec: Jijidown_Core_VideoType = .hevc

    /// 下载走哪个接口。
    ///
    /// 默认 WEB：实测 **TV / APP 现在建得起任务但下不出来** —— 核心在取播放
    /// 地址那一步报 `API TV not allowed` / `API APP not allowed`，产出零字节、
    /// 任务转错误。核心**不把错误文本回给客户端**（`TaskStatusReply` 没有错误
    /// 字段），所以事后只能按任务的 `api_type` 归因。界面上要如实说这一条。
    var downloadAPI: DownloadAPI = .web

    // MARK: 核心

    let core = CoreManager()
    /// 连到核心的 RPC 客户端。**只有本文件用** —— 视图要什么都走这个模型上的
    /// 方法，不直接摊到 RPC 那一层，所以是 `private`。
    private var client: CoreClient?
    private(set) var serverName = ""
    private(set) var serverOS = ""

    // MARK: 检查更新

    private(set) var updateStatus: Jijidown_Core_UpdateStatusType?
    private(set) var updateChangeLog = ""
    private(set) var isCheckingUpdate = false
    private(set) var updateError: String?
    private(set) var updateCheckedAt: Date?
    var updateChangeLogExpanded = false

    private var updateTask: Task<Void, Never>?

    /// 有没有值得摆到界面上的检查更新结果（成功或失败都算）。
    var hasUpdateNotice: Bool { updateStatus != nil || updateError != nil }

    // MARK: 登录

    var loginMethod: LoginMethod = .qr
    var loginAPI: Jijidown_Core_LoginQRCodeAPI = .tv
    var cookieInput = ""
    /// 官方客户端的 Cookie 导入界面写着 AccessToken「用于登录 TV、APP 接口」。
    /// **本项目未验证**：有它能不能让 TV / APP 通，没验过，别当结论用。
    ///
    /// 它是凭据，和 Cookie 同级：**不许拼进任何错误文案或日志**（下面的报错
    /// 统一过 `redacting`）。
    var accessTokenInput = ""
    /// 是否明文显示 AccessToken。放这里而不是视图的 `@State` —— 本机没有
    /// SwiftUI 宏插件，`@State` 编译不过（见类顶部说明）。
    var revealAccessToken = false

    private(set) var qrPNG: Data?
    /// 二维码是什么时候签发的。**只有本文件用**（算剩余秒数，见 `qrSecondsLeft`），
    /// 视图不直接读，所以是 `private`。
    private var qrIssuedAt: Date?
    private(set) var loginStatusText = ""
    private(set) var isLoggingIn = false
    private(set) var loginError: String?
    private(set) var isImportingCookie = false

    private var loginTask: Task<Void, Never>?

    /// 二维码剩余有效秒数。B 站二维码是 180 秒，留 10 秒余量提示用户。
    var qrSecondsLeft: Int? {
        guard let issued = qrIssuedAt else { return nil }
        let left = 170 - Int(Date().timeIntervalSince(issued))
        return max(0, left)
    }

    /// 能不能点「导入 Cookie」。视图绑这个，别自己拼条件。
    ///
    /// 关键是**先把空白剪掉再判空**：只粘了一堆空格换行的输入会让
    /// `cookieInput.isEmpty` 判成「有内容」，按钮亮着，点下去却静默返回 ——
    /// 用户看不见任何反馈，只会以为导入坏了。
    var canImportCookie: Bool {
        !cookieInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isImportingCookie
            && core.phase.isRunning
    }

    // MARK: 用户与任务

    private(set) var user: Jijidown_Core_UserInfoReply?
    var isLoggedIn: Bool { user?.isLogin ?? false }

    /// 最近一次取用户信息**为什么没取到**。取到了就是 nil。
    ///
    /// 单独一个字段，不并进 `loginError`：那个字段显示在登录面板里，含义是
    /// 「你刚才这次登录操作没成」；这里失败的是「刷新了一下用户信息」，用户
    /// 可能什么都没做（启动连上核心时、登录成功后、导入 Cookie 后都会调一次）。
    /// 界面拿它拼一句完整的说明（见 `AccountView`），所以这里是原因，不是整段文案。
    ///
    /// **失败时 `user` 保持原样**，所以这个字段是页面上唯一能看出「刚才是没问到，
    /// 不是你真的登出了」的地方（理由见 `refreshUser`）。
    private(set) var userError: String?

    private(set) var tasks: [Jijidown_Core_TaskStatusReply] = []

    /// 最近一次取任务列表**为什么没取到**。取到了就是 nil（哪怕是空列表）。
    ///
    /// 单独存一个字段，而不是并进 `parseError`：`parseError` 显示在「下载」页，
    /// 而这件事发生在「任务」页上，写过去用户根本看不到。界面拿它拼一句完整的
    /// 说明（见 `TaskListView`），所以这里是原因，不是整段文案。
    private(set) var tasksError: String?

    /// 最近一次**任务控制**（暂停 / 继续 / 删除 / 删除任务和文件）为什么没成。
    ///
    /// 单独一个字段，不并进 `tasksError`：那个字段的含义是「这一次没取到任务
    /// 列表」，界面照着这个意思写了一段说明（「下面还列着的是上一次取到的
    /// 内容」）。控制失败时列表是**取到了**的，塞进那个字段里，界面会当场说
    /// 一句与事实不符的话。
    ///
    /// 为什么这件事必须有个出口：`control` 发完请求紧跟一次 `refreshTasks()`，
    /// 界面随即刷成核心那边的真实状态。失败时用户看到的正好是**原封不动的那
    /// 一行** —— 点了「暂停」，状态还写着「下载中」，没有任何解释；反复点只会
    /// 反复如此，最后怀疑界面卡住了。删除同理：删不掉的任务原地复现。
    ///
    /// 这里存的是**给用户看的一整句话**（哪个任务、哪个动作、核心为什么拒绝），
    /// 因为「哪个任务」只有模型这边查得到（标题对照表在模型里）。
    private(set) var taskActionError: String?

    /// 任务 id → 我们给它起的标题（提交时那一份，不带撞名后缀）。
    ///
    /// 生命周期：只在内存里，App 退出即丢（见类顶部的说明）。
    private var taskTitles: [String: String] = [:]
    /// 任务 id → 产物的**主干名**（= 提交时的 `save_filename`，也就是核心回显在
    /// `task_title` 里的那个）。定位产物用它。
    private var taskStems: [String: String] = [:]
    /// 任务 id → 产物路径（「在访达中显示」用）。同样是内存态。
    ///
    /// **只有本文件用**：视图一律走 `savedPath(for:)` / `outputState(_:)` /
    /// `reveal(taskID:)`，不直接读这张表，所以是 `private`。
    private var savedPaths: [String: String] = [:]

    /// **模型已经不再给这些任务找产物了**的任务 id。
    ///
    /// 界面要说明「在访达中显示」为什么是灰的，靠的就是它。**不能让视图自己现算
    /// 「完成超过 30 秒且还没定位到」**：那是个墙钟谓词，不依赖任何被观察的状态，
    /// 只会在别的地方有字段变化引起重渲染时被顺带重算（每 2 秒一次的
    /// `refreshTasks` 就会改 `tasks`）。于是那行说明什么时候冒出来，由「下一次
    /// 重渲染恰好落在 30 秒之后」决定，而不是由状态决定 —— 用户正在浏览列表、
    /// 鼠标悬在下面某一行上准备按删除，说明凭空插进某一行（`TaskRow` 会因此变高
    /// 约 65pt），下面的行整体下移，他点中的换成了另一行，而整个过程他什么都没做。
    /// 记成状态之后，它出现的那一刻是模型**决定放弃的那一刻**，不再是渲染时随手
    /// 读的一次钟。
    ///
    /// 与 `locatedTaskIDs` 的区别：那个的含义是「这一条判过了，别再扫目录」，
    /// **定位成功的也记在里面**；这个只记没找到的，所以界面拿它当「找不到产物」
    /// 用不会把定位成功的行也带上。
    ///
    /// **只有本文件用**：界面读的是 `outputState(_:)`，不直接读这个集合，
    /// 所以是 `private`。
    private var gaveUpTaskIDs: Set<String> = []

    private var claimedTaskIDs: Set<String> = []
    private var locatedTaskIDs: Set<String> = []

    /// 提交出去、还没在任务列表里露面的任务：`save_filename` → 界面标题。
    /// 核心回显的 `task_title` 拿它反查，配上了才认领。
    private var pendingTitles: [String: String] = [:]
    /// 本次运行已经占用的主干名。防覆盖要用（见类顶部「App 一退就没」那段）。
    private var reservedStems: Set<String> = []

    /// **配不上标题**的任务 id。
    ///
    /// 这一项必须露在界面上，不能悄悄吞掉：核心没回显 `task_title` 时我们
    /// 就不再按列表顺序硬配（实测顺序不稳定，硬配出来的是错名字）。
    /// 结果就是这些任务在界面上没有标题 —— 得让用户知道「没配上」，
    /// 而不是让他对着一行空标题猜。
    private(set) var unpairedTaskIDs: Set<String> = []
    var hasUnpairedTasks: Bool { !unpairedTaskIDs.isEmpty }

    // MARK: 解析

    private(set) var parsedVideo: Jijidown_Core_BvideoInfoReply?
    private(set) var qualities: Jijidown_Core_BvideoAllQualityReply?

    /// 取清晰度列表失败的原因。
    ///
    /// 存在的理由是**界面得知道自己为什么拿到 nil**：`qualities == nil` 底下
    /// 至少罩着三种情形 —— 请求发出去失败了（超时、UNAVAILABLE、核心中途停掉）、
    /// 核心的会员门挡了、以及 `AllQuality` **一次都没被调用**（视频没有 cid
    /// 非 0 的分P，`parse` 里那个 `if let` 整个没进去）。
    ///
    /// 判据就靠它与 `qualities` 的组合，不另设标志位：
    /// - `qualities != nil` —— 查到了；
    /// - `qualities == nil && qualitiesError == nil` —— **没查过**；
    /// - `qualities == nil && qualitiesError != nil` —— 查了但失败。
    ///
    /// 这里必须留住**原始错误**而不是一句写死的说明：以前界面把成因认成
    /// 「核心的会员门」，于是一次超时被说成「你的账号不行，重试也没用」。
    private(set) var qualitiesError: CoreError?
    var input = ""
    private(set) var isParsing = false
    /// 正在提交下载任务。界面绑它把「开始下载」按下去，别让第二次点击挤进来。
    ///
    /// 为什么必须让按钮也参与：`enqueue` 跨了 `await`（每条任务一次
    /// `client.newTask`），而 `@MainActor` 是**可重入**的 —— 挂起期间同一个
    /// actor 上的另一个任务照样能跑起来。只靠按钮的 disabled 不够快（置位要等
    /// 下一次主 actor 轮转），真正兜底的是 `enqueue` 入口那道闸；按钮这层只是
    /// 别让用户点出一个「点了没反应」的错觉。
    private(set) var isEnqueuing = false
    /// 解析阶段的错误。**提交任务失败也写这里** —— 两条路都在「下载」页上操作，
    /// 界面上本来就是同一个位置。
    private(set) var parseError: String?

    private var pollTask: Task<Void, Never>?

    // MARK: - 核心启动

    func bootCore() async {
        await core.start()
        guard core.phase.isRunning else { return }
        await connect()
    }

    /// 收尾：停掉本地这几条流，再把核心进程带走。
    ///
    /// - Parameter terminating: 是不是在「进程马上就要退出」的路径上调用（也就是
    ///   `applicationWillTerminate`）。两个调用点的区别只有一处：要不要顺手做 gRPC
    ///   的优雅关闭，理由见下面那段。
    func shutdown(terminating: Bool = false) {
        pollTask?.cancel()
        loginTask?.cancel()
        // 检查更新那条流也要收：核心可能根本不关流，断了连接它才会停。
        updateTask?.cancel()
        updateTask = nil
        isCheckingUpdate = false
        core.stop()

        // 「核心」页那颗「停止核心」按钮走的是 `terminating == false` 这条路：App 还
        // 接着跑，收掉旧 client 才有人把它那条连接放干净（否则它会留着一条连到已死
        // 核心的连接，下一轮启动又建一条）。这里 `Task { }` 能跑起来，是因为主队列
        // 还会被抽。
        //
        // 退出路径（`terminating == true`）**故意不做这件事 —— 做了也不会发生**：
        // `applicationWillTerminate` 一返回 AppKit 就开始退进程，而这种没人 await 的
        // `Task { }`（本类在 MainActor 上，它继承同一个执行器）要等主队列再被抽一次
        // 才轮到，那个时机不会再来。于是 `beginGracefulShutdown` 与
        // `await runTask?.value` 一次都跑不到 —— 原来这里只有一句「优雅关闭」，代码
        // 从没执行过，注释与代码互相背书了一个假象。退出时连接是被硬断的，核心侧
        // 看到的是连接中断而不是 GOAWAY。
        //
        // 这不要紧，也不值得去补：上一行的 `core.stop()` 已经用 SIGTERM 把核心带走
        // 了，对端本来就在消失；真在这儿同步等它，只会把退出拖住（甚至卡在等一个
        // 永远不会来的收尾），换不来任何东西。
        if !terminating, let client { Task { await client.shutdown() } }
    }

    private func connect() async {
        do {
            let client = try CoreClient()
            await client.start()
            self.client = client
            let pong = try await client.ping()
            serverName = pong.serverName
            serverOS = pong.osSystemName
            await refreshUser()
            startPolling()
        } catch {
            parseError = "连接核心失败：\(error)"
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTasks()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refreshTasks() async {
        guard let client else { return }
        // 列全部任务。实测 `Task.List` 传 0 是**不过滤**（见 CoreClient.listTasks），
        // 所以这里走 listAllTasks()，而不是把 `.taskError` 这个名字写在过滤位上。
        //
        // **「取失败」和「真的没有任务」是两条路，不能合成一条。**
        //
        // 老代码是一句 `if let list = try? await client.listAllTasks(), !list.isEmpty`：
        // `try?` 把异常啃成 nil，异常和空列表落进同一个 else，于是**一次抖动就把
        // 整个任务列表清成空**，界面换成「还没有任务 / 去「下载」页粘贴一个 B 站
        // 链接」，错误一个出口都没有。会命中的场合一点不罕见：核心意外退出后
        // 自己重启（最长 60 秒等就绪，见 `CoreManager.handleTermination`），或者
        // 一次瞬时的 unavailable / deadline。任务其实还在核心那边跑，用户却以为
        // 被删了 —— 列表、行内归因说明、没配上对的标记一起闪没。
        //
        // 所以失败时**保留上一次的列表**（核心那边什么都没变），只把原因记进
        // `tasksError` 让界面说出来；只有真的拿到空数组才清空。
        do {
            tasks = try await client.listAllTasks()
            tasksError = nil
        } catch {
            tasksError = Self.rpcFailureReason(error)
            // 列表没变，后面的配对与产物定位没有新东西可算，直接收工 ——
            // 否则核心没在跑的日子里还要每 2 秒白扫一次下载目录。
            return
        }

        claimNewTasks()
        await collectFinishedOutputs()
        // 已经不存在的任务不必继续挂着「配不上」的牌子。
        unpairedTaskIDs.formIntersection(tasks.map(\.taskID))
    }

    /// 一次 RPC 失败的原因，给界面拼说明用（`refreshTasks` 和 `refreshUser`
    /// 都用它，两边的失败长得一样，措辞就不该有两套）。
    ///
    /// 能确定的只有「这次没取到」，所以措辞就停在这里 —— 核心为什么不响应，
    /// 客户端不知道，不替它下断言（原因的解释与下一步在界面上说，见
    /// `TaskListView` / `AccountView`）。
    private static func rpcFailureReason(_ error: Error) -> String {
        guard let error = error as? CoreError else { return String(describing: error) }
        // `.rpc` 那几支的 guidance 和 description 是同一句，贴两遍只是噪音；
        // 真正多给信息的（比如「核心未运行」）才两句都留。
        return error.guidance == error.description
            ? error.description
            : "\(error.description)\n\n\(error.guidance)"
    }

    /// 把还没认领的任务和提交时记下的标题配上对。
    ///
    /// ## 判据是核心回显的 `task_title`，不是列表顺序
    ///
    /// `Task.New` 返回的是 `google.protobuf.Empty`，核心**不告诉我们新建的任务
    /// id**。老办法是「等新任务出现在列表里，按出现顺序认领排队中的标题」——
    /// 实测站不住：**同一份列表连读两次顺序就会翻转**，第一次读还可能正好与
    /// 提交顺序相反，配出来的标题是错的。
    ///
    /// 实测可靠的凭据是 `task_title`：**核心把它设成我们提交的 `save_filename`
    /// 原样回显**（不传时是空串）。所以提交时给每个任务一个唯一的主干名，
    /// 回来时拿它反查即可，与列表顺序无关。
    ///
    /// 反查不到的**不给标题**（宁可空着，界面会退回显示回显名），并记进
    /// `unpairedTaskIDs` 让界面说出来；但**主干名照记**，见下。
    ///
    /// ## 「配不上对」只影响标题，不影响定位产物
    ///
    /// 老代码把这两件事绑成了一件：反查失败就 `continue`，`taskStems` 一个字不写，
    /// 而 `collectFinishedOutputs` 的候选条件里正卡着「没有 `taskStems` 就跳过」。
    /// 可是配对失败只说明**本地那本标题对照表里没有它**，不等于没有主干名 ——
    /// 回显的 `task_title` 本身就是主干名 —— 核心就是按 `save_filename` 给产物
    /// 命名的，客户端这边则拿它去目录里比对（`CoreManager.locateOutput` →
    /// `OutputNaming.newestMatch` / `matches`），照着记不是猜。不记的后果很具体：这些任务被定位整个跳过，
    /// 产物躺在下载目录里，「在访达中显示」却永远灰着，还弹一句归因错误的
    /// 「没找到产物」。
    ///
    /// 哪些任务会走到这条路：命令行探针 / 官方客户端 / 另一个实例建的（它们跑在
    /// 同一个核心上，同样出现在这里的 `Task.List` 里），以及本 App 重启前建的
    /// （对照表只在内存里，重启即空）。
    ///
    /// 老代码还在这里有个顺序 bug：`claimedTaskIDs.insert` 写在判空之前，
    /// 于是没有标题可配的任务也被标成「已认领」，再也不会重试。
    private func claimNewTasks() {
        for task in tasks where !claimedTaskIDs.contains(task.taskID) {
            let echoed = task.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let label = pendingTitles.removeValue(forKey: echoed) else {
                unpairedTaskIDs.insert(task.taskID)
                // 只在回显非空时记：核心连 `task_title` 都没回显的任务（提交时没传
                // `save_filename` 的那些）才是真的无从定位。
                if !echoed.isEmpty { taskStems[task.taskID] = echoed }
                continue
            }
            claimedTaskIDs.insert(task.taskID)
            unpairedTaskIDs.remove(task.taskID)
            taskTitles[task.taskID] = label
            taskStems[task.taskID] = echoed
        }
    }

    /// 已完成的任务：到下载目录里按主干前缀认领**它自己的**产物。
    ///
    /// 只在下载完成后做 —— 核心是合并阶段才把文件落盘的。
    private func collectFinishedOutputs() async {
        // 候选是「下完了、这一条还没判过」的任务。**这里先不筛主干名** —— 没有
        // 主干名的同样要判一次，只不过判的是「直接放弃」，见下面那个循环。
        let candidates = tasks.filter {
            $0.isFinished && !locatedTaskIDs.contains($0.taskID)
        }
        guard !candidates.isEmpty else { return }

        // 核心连 `task_title` 都没回显的任务（提交时没传 `save_filename` 的，
        // 探针 / 官方客户端 / 另一个实例建的都会是这样），我们没有东西可以拿去
        // 和目录里的文件名比对 —— 进不了下面的定位循环，也就是**永远找不到了**，
        // 当场记放弃。
        //
        // 不记的后果是那些行在界面上没有任何解释：`Controls` 里那句注释承诺过
        // 「为什么点不动」得靠行内那行说明，文件夹按钮灰着而旁边一句话都没有，
        // 用户只会以为界面坏了。
        for task in candidates where taskStems[task.taskID] == nil {
            gaveUpTaskIDs.insert(task.taskID)
        }

        let pending = candidates.filter {
            // 主干名来自核心回显的 `task_title`，**配不上对的任务也有**
            // （见 `claimNewTasks`）。只有核心连它都没回显时才为空 ——
            // 那些上面已经判过了。
            taskStems[$0.taskID] != nil
        }
        guard !pending.isEmpty else { return }

        // 目录只读一次，且丢到主 actor 外面读（同 enqueue）。
        let names = await Self.fileNames(in: core.downloadDirectory)

        for task in pending {
            guard let stem = taskStems[task.taskID] else { continue }
            // 扩展名从任务回复的 `audio_only` 推 —— 和提交时避让用的是同一条规则
            // （`OutputNaming.ext(audioOnly:)`）。不带上它的话，主干同名但另一种
            // 扩展名的产物会被认成这个任务的：App 重启后内存对照表已空，这一趟
            // 是唯一的重新认领机会，认错就把「在访达中显示」指到别的文件上。
            let ext = OutputNaming.ext(audioOnly: task.audioOnly)
            if let url = core.locateOutput(stem: stem, among: names, ext: ext) {
                locatedTaskIDs.insert(task.taskID)
                savedPaths[task.taskID] = url.path
            } else if Date().timeIntervalSince1970 - Double(task.completeTime) > 30 {
                // 收尾都过 30 秒了还没落盘，多半就是没有（任务出错时也可能
                // 有 complete_time）。不再每 2 秒扫一次目录，`locateOutput`
                // 的日志里留了记录。
                //
                // 这里同时就是「放弃」这一刻：`locatedTaskIDs` 管的是**不再扫**，
                // 界面要知道的是**不再找**（`gaveUpTaskIDs`）。两个集合分开，
                // 是因为定位成功那条路也往 `locatedTaskIDs` 里插。
                locatedTaskIDs.insert(task.taskID)
                gaveUpTaskIDs.insert(task.taskID)
            }
        }
    }

    /// 取一次用户信息（核心那边现在是登录着的谁）。
    ///
    /// **失败不改 `user`。** 老代码是一句 `user = try? await client.userInfo()`：
    /// `try?` 把异常啃成 nil，异常和「核心说没登录」落进同一个结果里，于是**一次
    /// 瞬时失败就把账号页清成未登录** —— 界面上那张已登录卡当场换成登录卡，用户
    /// 看到的是「我被登出了」，而核心那边的登录态根本没变。会命中的场合一点不
    /// 罕见：核心意外退出后自己重启（最长 60 秒等就绪，见
    /// `CoreManager.handleTermination`），或者一次瞬时的 unavailable / deadline。
    /// 更别扭的是用户接着会去扫码，而已登录时核心不给二维码（`beginLogin` 的
    /// `.rpc` 分支），于是他又撞上一句「核心拒绝了取码请求」。
    ///
    /// 和 `refreshTasks` 一个口径：失败保留上一次的结果，只把原因记进 `userError`
    /// 让界面说出来（那一页由 `AccountView` 显示）。只有真的拿到回复才写 `user`。
    func refreshUser() async {
        guard let client else { return }
        do {
            user = try await client.userInfo()
            userError = nil
        } catch {
            userError = Self.rpcFailureReason(error)
        }
    }

    // MARK: - 检查更新

    /// 手动检查更新。核心页的按钮调它。
    ///
    /// 三件必须知道的事：
    ///
    /// 1. **这是核心启动时那次检查的回放，不是重新联网。** 实测每次只回 1 条
    ///    （本机 status=1 NOTSUPPORTUPDATE + 195 字 changelog），反复调内容
    ///    一模一样。所以触发方式是手动的 —— 核心启动时自己已经查过一次，
    ///    我们没必要替用户反复打服务器。
    /// 2. **只提示，不下载不安装**（用户已定）。这里只读 `status` 与
    ///    `changeLog`，看到 NEEDUPDATE 也不做任何动作。
    /// 3. 防重入：已经在查就直接返回，按钮可以放心连点。
    func checkUpdate() {
        guard updateTask == nil else { return }
        isCheckingUpdate = true
        updateError = nil
        updateTask = Task { [weak self] in
            guard let self else { return }
            await self.performCheckUpdate()
            self.isCheckingUpdate = false
            self.updateTask = nil
        }
    }

    private func performCheckUpdate() async {
        guard let client else {
            updateError = "核心还没连上，先把「核心」页的问题解决掉。"
            return
        }
        do {
            // 超时是核心那侧可能不关流的保险（见 CoreClient.checkUpdate），
            // 到点按正常结束收尾：已经收到的内容仍然有效。
            for try await reply in client.checkUpdate() {
                updateStatus = reply.status
                if !reply.changeLog.isEmpty { updateChangeLog = reply.changeLog }
                // CHECKING(0) 在核心那里是「检查中 / 下载更新」合一的状态，
                // 是**过程**不是结论 —— 收到别的才 break，否则会把唯一一条
                // 结论当成进度丢掉。
                if reply.status != .checking { break }
            }
            updateCheckedAt = Date()
            if updateStatus == nil {
                // 一条都没回。实测核心至少会回一条（启动时那次检查的结果），
                // 这里如实说是「没拿到结论」，不要说成「已是最新版本」——
                // 那是替核心下断言。
                updateError = """
                    核心这次一条都没回（到了 20 秒的超时上限）。
                    它平时至少会回一条 —— 那是核心启动时那次检查的结果。\
                    没回就说明这次没拿到结论，稍后可以再点一次。
                    """
            }
        } catch let error as CoreError {
            // 只说一句错误码帮不到用户，正文 + `guidance` 的建议一起给。
            updateError = "\(error.description)\n\n\(error.guidance)"
        } catch {
            // App 退出时主动断的流不该报成「检查失败」。
            if Task.isCancelled { return }
            updateError = String(describing: error)
        }
    }

    /// 用户关掉检查更新的提示。
    ///
    /// `updateCheckedAt` 特意留着：提示关掉了，「上次检查是什么时候」这件事
    /// 仍然是用户判断要不要再点一次的依据。
    func dismissUpdateNotice() {
        updateStatus = nil
        updateError = nil
        updateChangeLog = ""
        updateChangeLogExpanded = false
    }

    // MARK: - 扫码登录

    /// 进登录页时调用：等核心就绪后自动取一张二维码。
    ///
    /// 必须等 —— `AccountView` 的 `.task` 在视图出现时就跑了，而那时核心
    /// 通常还在启动（要好几秒），直接取码会因为没有 client 而静默跳过。
    func beginLoginIfNeeded() async {
        guard !isLoggedIn else { return }
        for _ in 0..<80 {
            if core.phase.isRunning, client != nil { break }
            if case .failed = core.phase { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard core.phase.isRunning, client != nil, !isLoggedIn else { return }
        guard qrPNG == nil, !isLoggingIn else { return }
        await beginLogin()
    }

    /// 取一张新二维码并开始轮询扫码结果。
    ///
    /// 两个实测细节：
    /// 1. **已登录时核心会让 `LoginQRCode` 直接报错** —— 这不是失败，
    ///    要当成「已经登录了」处理。
    /// 2. `LoginStatus` 是服务端流，核心推一次状态变化我们收一次。
    func beginLogin(api: Jijidown_Core_LoginQRCodeAPI? = nil) async {
        guard let client else {
            loginError = "核心还没连上"
            return
        }
        let api = api ?? loginAPI
        cancelLogin()

        isLoggingIn = true
        loginError = nil
        qrPNG = nil
        qrIssuedAt = nil
        loginStatusText = "正在获取二维码…"

        do {
            let (png, id) = try await client.loginQRCode(api: api)
            qrPNG = png
            qrIssuedAt = Date()
            loginStatusText = "等待扫码"

            loginTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await status in client.loginStatus(id: id) {
                        await MainActor.run { self.loginStatusText = Self.describe(status) }

                        if status.loginSuccessful || status.status == .succeeded {
                            await MainActor.run {
                                self.loginStatusText = "登录成功"
                                self.isLoggingIn = false
                                self.refreshAfterLogin()
                            }
                            // 登录后核心会去 sabe.cc 换授权，给它一点时间。
                            try? await Task.sleep(for: .seconds(2))
                            await self.refreshUser()
                            await self.refreshTasks()
                            return
                        }
                        if status.status == .expired {
                            await MainActor.run {
                                self.loginStatusText = "二维码已失效"
                                self.isLoggingIn = false
                                self.qrPNG = nil
                                self.qrIssuedAt = nil
                            }
                            return
                        }
                    }
                    // 流正常结束 —— 既没登录成功、核心也没推 expired，只是把流关了。
                    // 上面三条出口都不走的话，`isLoggingIn` 会永远停在 true：界面一直
                    // 转圈等人扫码，而码其实早就没人在听了，只剩「取消」可点。所以
                    // 这里按「这次扫码作废」收尾，并写清下一步怎么办。
                    //
                    // 只说「流结束了，没拿到结果」，不说成「二维码已失效」：我们看到的
                    // 只是流结束，核心为什么关流**没有实测依据**，不替它下断言。
                    //
                    // `Task.isCancelled` 这一问是给「用户自己点了取消」留的：那种结束也
                    // 走这条路（实测取消消费者不抛错，只让 for-await 正常返回），而
                    // `cancelLogin` 已经收好尾了，再写一次就会把「我取消的」改说成
                    // 「没拿到结果」。**不能拿 `isLoggingIn` 当判据**：换码时 `beginLogin`
                    // 会先 cancel 再立刻把 `isLoggingIn` 置回 true，旧任务这时才醒过来，
                    // 一判就会把新码的状态清掉。
                    if !Task.isCancelled {
                        await MainActor.run {
                            self.loginStatusText = "登录状态流结束了，没拿到结果，可以重新获取二维码"
                            self.isLoggingIn = false
                            self.qrPNG = nil
                            self.qrIssuedAt = nil
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.loginError = "登录状态流中断：\(error)"
                        self.isLoggingIn = false
                    }
                }
            }
        } catch let error as CoreError {
            isLoggingIn = false
            // 已登录时核心会拒绝再发二维码 —— 这不是错误。
            loginStatusText = "核心拒绝了取码请求，可能已经登录了。"
            await refreshUser()
            if !isLoggedIn { loginError = error.description }
        } catch {
            isLoggingIn = false
            loginError = String(describing: error)
        }
    }

    /// 登录成功后清掉解析错误（那个错误多半就是授权门导致的，现在应该没了）。
    private func refreshAfterLogin() {
        parseError = nil
    }

    /// 取消这次扫码，并把界面上跟它绑在一起的状态一并收掉。
    ///
    /// **光收流、复位 `isLoggingIn` 是不够的。** 二维码图和倒计时都不归那条流管：
    /// 倒计时是 `TimelineView` 按 `qrIssuedAt` 自己算的，`qrPNG` 也一直留在那儿。
    /// 只清 `isLoggingIn` 的话，「取消」按钮跟着消失，码却还在屏幕上、还在倒计时
    /// —— 用户看见一个能扫、但已经没人在听的码。他真去扫并在手机上确认，App 不会
    /// 有任何反应：流已经断了，而切回本页时 `beginLoginIfNeeded` 的
    /// `guard qrPNG == nil` 又把自动重取拦住了。
    ///
    /// 状态文案写「已取消登录」而不是留空：这样「我点的取消」和「码自己失效了」
    /// 在界面上分得清，用户知道自己那一下生效了。
    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        isLoggingIn = false
        qrPNG = nil
        qrIssuedAt = nil
        loginStatusText = "已取消登录"
    }

    private static func describe(_ s: Jijidown_Core_UserLoginStatusReply) -> String {
        switch s.status {
        case .unknown: "等待中…"
        case .succeeded: "登录成功"
        case .expired: "二维码已失效"
        case .unscanned: "等待扫码"
        case .unconfirmed: "已扫码，请在手机上确认"
        case .UNRECOGNIZED: "未知状态"
        }
    }

    // MARK: - Cookie 导入

    /// 校验用户粘贴的 Cookie 串是否含核心要求的字段。
    ///
    /// 核心自己也会校验，但提前拦一手能给出更清楚的提示。
    static func missingCookieFields(_ raw: String) -> [String] {
        let required = ["DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct", "sid", "buvid3"]
        return required.filter { !raw.contains($0) }
    }

    func importCookie() async {
        // 重入闸，**必须是函数体第一件事**（在任何 `await` 之前），和 `enqueue`
        // 入口那道同理。
        //
        // 按钮上那条 `.disabled(!canImportCookie)` 挡不住紧挨着的第二下：禁用要等
        // SwiftUI 重绘才生效，而两次点击各自 `Task { await importCookie() }`。
        // `@MainActor` 是可重入的，第一次在 `await client.importCookie` 处让出主
        // actor 之后，第二次会从头再跑一遍校验、再发一次 `ImportCookie` —— 白白多
        // 一趟 RPC。更别扭的是先收尾的那次会用 `defer` 把 `isImportingCookie` 复位，
        // 于是进度圈在另一次还在跑的时候就消失，看着像「导入完了」。
        //
        // 这里静默返回、不写 `loginError`：前一次还在跑，它自己会给出反馈；
        // 再报一句只会凭空造出一条假失败。
        guard !isImportingCookie else { return }

        guard let client else {
            loginError = "核心还没连上"
            return
        }
        let raw = cookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            // 按钮那边已经用 `canImportCookie` 剪过空白了，这里再兜一道：
            // 静默返回是最难排查的一种失败。
            loginError = "Cookie 是空的（只有空格换行也算空）。"
            return
        }

        let missing = Self.missingCookieFields(raw)
        guard missing.isEmpty else {
            loginError = "Cookie 里缺少这些字段：\(missing.joined(separator: "、"))"
            return
        }

        // AccessToken 是可选的（官方客户端说它用于 TV / APP 接口，本项目未验证），
        // 但它是凭据 —— 后面任何一句话都不能把它带出去。
        let token = accessTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)

        isImportingCookie = true
        loginError = nil
        defer { isImportingCookie = false }

        // 交给核心之前先登记：核心会把请求内容打进 stdout（它自己的 `[rpc]` 日志
        // 就带请求现场），而托管日志是逐行镜像它的。登记之后，日志面板与
        // manager.log 里只会留下占位符。空串由 `registerSecret` 自己挡掉。
        core.registerSecret(raw)
        core.registerSecret(token)

        do {
            try await client.importCookie(cookies: raw, accessToken: token)
            // 导入后立刻把两个输入框都清掉 —— 凭据不该长时间留在界面上。
            cookieInput = ""
            accessTokenInput = ""
            revealAccessToken = false
            loginStatusText = "已导入，正在确认…"
            try? await Task.sleep(for: .seconds(2))
            await refreshUser()
            if userError != nil {
                // 这一次没问到用户信息，**不能照着 `isLoggedIn` 下结论**：它现在
                // 还是上一次的结果（`refreshUser` 失败时不清空），照着说就会对
                // 一个刚导入成功的用户说「仍是未登录，检查 Cookie 是否过期」——
                // 正好是「不对已登录的用户说去登录」那类假失败。原因已经由
                // `userError` 在页面上说出来了，这里只报自己的结论：没问到。
                loginStatusText = "已导入 Cookie，但这次没取到用户信息"
            } else if isLoggedIn {
                loginStatusText = "登录成功"
            } else {
                loginError = "核心接受了 Cookie 但用户信息仍是未登录，检查 Cookie 是否过期。"
            }
        } catch {
            loginError = redacting("导入失败：\(error)", secret: token)
        }
    }

    /// 兜一道：万一核心把请求内容回显进错误消息里，凭据也不能出现在界面上。
    ///
    /// 短于 8 个字符的「凭据」不做替换 —— 那种长度替换起来容易误伤正常文字。
    private func redacting(_ text: String, secret: String) -> String {
        guard secret.count >= 8 else { return text }
        return text.replacingOccurrences(of: secret, with: "＜已隐去＞")
    }

    // MARK: - 解析

    /// 解析输入框里的链接，结果写进 `parsedVideo` / `qualities` / `selectedCids`。
    ///
    /// 重入闸，**必须是函数体第一件事**（在任何 `await` 之前）。
    ///
    /// 不加这道闸会出事：界面上那个「解析」按钮确实绑了 `.disabled(... || isParsing ...)`，
    /// 但输入框的 `.onSubmit` 不经过按钮 —— 在地址栏里敲回车能直接调到这里，
    /// disabled 拦不住它（ParseView 里那个 `Button("解析")` 才是被拦的那个）。
    /// `@MainActor` 是可重入的：第一次 `parse` 会在 `checkContent` / `videoInfo`
    /// 处让出主 actor，第二次趁这段时间进来，两边各写一份 `parsedVideo` 与
    /// `selectedCids`；先发的那次 `allQuality` 回来还会把 `qualities` 写成
    /// **它那一份**结果 —— 界面就成了「B 的视频配 A 的清晰度列表」，
    /// 而 ParseView 里「这份列表是解析时按第一个分P 查的」那句说明这时是错的
    /// （列表查的不是当前这个视频），`selectedCids` 里属于上一个视频的 cid
    /// 也会一直留着。错误分支同理：先发那次失败时会在后一次成功之后把
    /// `parseError` 写上，用户看到一个不该有的报错。
    ///
    /// 这里静默返回、不写 `parseError`：前一次还在跑，界面上的「解析中…」
    /// 就是反馈；再报一句只会凭空造出一条假失败。
    ///
    /// 「查 + 置位」之间没有 `await`，所以在主 actor 上是原子的：第二次进来
    /// 的调用必然看得见 true。
    func parse() async {
        guard !isParsing else { return }
        guard let client else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isParsing = true
        parseError = nil
        parsedVideo = nil
        qualities = nil
        qualitiesError = nil
        selectedCids = []
        defer { isParsing = false }

        do {
            let check = try await client.checkContent(text)
            guard check.isValid else {
                parseError = "这个链接核心没认出来，检查一下 BV 号或地址。"
                return
            }
            let info = try await client.videoInfo(text)
            parsedVideo = info

            // 默认只选第一个分P。**不默认全选**：核心多半是串行下载（`max-task: 1`，
            // 见 CoreManager.writeConfig；那条早退分支上没落地，它就可能并行，
            // 界面的说法见 ParseView.serialNote），100 个分P 全选等于排几小时队，
            // 而用户多半只想要第一个。
            if let first = info.allPages.first(where: { $0.pageCid != 0 }) {
                selectedCids = [first.pageCid]
                // 查不到就查不到，**但原因必须留下**（`qualitiesError`）。
                // 以前这里是 `try?`，把超时、UNAVAILABLE、核心中途停掉一律压成
                // nil；界面拿不到任何线索，只能自己编一个成因，于是编成了
                // 「核心的会员门」。
                //
                // **不写 `parseError`**：没有清晰度列表照样能选档位、发任务
                // （`video_quality` 是直接发给核心的），弹一条全宽的错误条等于
                // 把一次成功的解析说成失败。这条原因只配「拿不到清晰度列表」
                // 那一段说明用。
                do {
                    qualities = try await client.allQuality(bvid: first.pageBv, cid: first.pageCid)
                } catch let error as CoreError {
                    qualitiesError = error
                } catch {
                    // 正常到不了这里（`CoreClient.allQuality` 已经把一切都包成
                    // `CoreError`），兜底只是为了不留一个静默的 nil。
                    qualitiesError = .rpc(code: "LOCAL", message: String(describing: error))
                }
            }
        } catch let error as CoreError {
            // 只说一句错误码帮不到用户，所以正文 + `guidance` 的建议一起给。
            parseError = "\(error.description)\n\n\(error.guidance)"
        } catch {
            parseError = String(describing: error)
        }
    }

    // MARK: - 下载

    /// 一次提交的部分分P 没建起来时的记录。
    private struct SubmissionFailure {
        let page: Jijidown_Core_BvideoPage
        /// 这一项为什么没成。
        let reason: String
        /// 核心给的建议。本地错误没有（那是我们自己抛的，没有 guidance）。
        let guidance: String?
    }

    /// 批量建任务：**逐条** `Task.New`。
    ///
    /// 为什么不用 `Task.NewBatch`：实测核心用授权门把它挡死了
    /// （`failedPrecondition: DownloadBatch function not allowed`，
    /// 与登录前的 `DownloadVideo` 同形）。批量下载只能自己做循环。
    ///
    /// - Parameter pages: 要下的分P，**参数顺序就是提交顺序**，调用方直接把
    ///   `selectedPages` 传进来即可（那个属性已经按视频里的分P 顺序排好）。
    func enqueue(pages: [Jijidown_Core_BvideoPage]) async {
        // 重入闸，**必须是函数体第一件事**（在任何 `await` 之前）。
        //
        // 不加这道闸会出事：按钮上只有 `.disabled(count == 0)`，而它同时绑了
        // `.keyboardShortcut(.defaultAction)`（回车就能触发），双击或按住回车
        // 会让两次 `enqueue` 重叠。`@MainActor` 是可重入的，两次调用都会在
        // `await client.newTask` 处让出主 actor，于是各自拿着**还不含对方主干**
        // 的那份 `reservedStems` 去算 `availableStem` —— 同一个分P 算出同一个
        // 主干名，两条 `save_filename` 一模一样的 `Task.New` 发出去。
        //
        // 之后按参数是否相同分两种走法：
        // - 参数完全相同：核心按参数去重，第二条回 `task already exists`
        //   （用户只点了一次，却看到一条假失败）；核心**若**串行执行而不去重，
        //   后一个任务的产物就按同名静默覆盖前一个 —— 它不加 ` (2)` 也不报错，
        //   这一条本项目没实测到，是核心行为的已知风险而非当场结论。
        // - 两次点击之间改了清晰度（参数不同，去重更兜不住）：两条任务共用同一
        //   个主干名。以下是从代码推出来的，不是实测：`pendingTitles` 的
        //   removeValue 只够配一条，另一条**永远**进 `unpairedTaskIDs`；两条的
        //   `taskStems` 又都是这个名字，`locateOutput` 会对两行返回同一份
        //   「最新匹配文件」，两行的「在访达中显示」指向同一个路径。
        //
        // 这里静默返回、不写 `parseError`：前一次还在跑，它自己会给出反馈；
        // 再报一句只会凭空造出一条假失败。
        //
        // 「查 + 置位」之间没有 `await`，所以在主 actor 上是原子的：第二次进来
        // 的调用必然看得见 true。
        guard !isEnqueuing else { return }
        isEnqueuing = true
        defer { isEnqueuing = false }

        guard let client else {
            parseError = "核心还没连上，先把「核心」页的问题解决掉。"
            return
        }
        let pages = pages.filter { $0.pageCid != 0 }
        guard !pages.isEmpty else {
            parseError = "没有选中任何分P。cid 为 0 的分P 核心接受不了，会被跳过。"
            return
        }

        // —— 本次提交的参数快照，必须在**第一个 `await` 之前**读齐 ——
        //
        // 这几个值平时就是界面上的控件，而提交期间界面没有任何锁：一旦让出
        // 主 actor，用户就能改「仅下载音频」、换「接口」，或者在地址栏敲回车
        // （`.onSubmit` 那个入口不受 `isParsing` 约束，而 `parse()` 开头就把
        // `parsedVideo` 置 nil，紧接着可能换上另一个视频）。
        //
        // 逐个在循环里现取的后果是「同一批」并不共享同一组参数：勾 5 个分P
        // 点下去、紧接着勾上「仅下载音频」，前两个下 mp4、后三个下 mp3，
        // 而界面上的「仅音频」标签只解释了其中一部分；中途换成 TV/APP 接口，
        // 后半批就是零字节 + 任务转错误（实测那两个接口在取播放地址那步必失败）。
        //
        // 标题那一路更隐蔽：`taskLabel` 现取 `parsedVideo`，中途换了视频的话，
        // 后半批会拿**另一个视频**的标题当主干名，这个错名字还会经
        // `pendingTitles` 一路带到「任务」页。
        //
        // 读成局部常量之后循环里只认这一份：提交期间被改动的参数只影响下一批，
        // 不影响正在跑的这批 —— 「一次提交 = 一组参数」。
        let video = parsedVideo
        // 多分P 的视频才加 `P<序号> ` 前缀：单分P 加了只是噪音。
        let multiPart = (video?.allPages.count ?? 1) > 1
        let quality = self.quality
        let audio = self.audio
        let codec = self.codec
        let downloadAPI = self.downloadAPI
        let audioOnly = self.audioOnly

        // 目录里已有的文件名**读一次**，而且丢到主 actor 外面读 ——
        // 目录大起来时 `contentsOfDirectory` 会有可感的停顿，不值得卡住界面。
        // 一次批量里的所有分P 共用这一份清单，新增的占用走 `taken` 记账。
        let existingNames = await Self.fileNames(in: core.downloadDirectory)

        // 这一份快照能一直用到循环结束，靠的是入口那道重入闸：它保证同一时间
        // 只有一次 `enqueue` 在跑，`reservedStems` 在本次循环期间不会被别人改。
        var taken = reservedStems
        var failures: [SubmissionFailure] = []
        var created = 0

        for page in pages {
            // `video:` 用的是上面那份快照，不是 `parsedVideo` 属性：
            // 循环里每一次 `await` 都可能让界面把 `parsedVideo` 换成别的视频。
            let label = Self.taskLabel(for: page, multiPart: multiPart, video: video)
            var base = OutputNaming.sanitized(label)
            if base.isEmpty {
                // 标题被清成了空（比如整条都是点号）。主干不能为空 ——
                // 空主干就是老版本那个「文件名以一个空格开头」的烂摊子。
                base = page.pageBv.isEmpty ? "task" : page.pageBv
            }
            // 扩展名按快照里的 `audioOnly` 定，规则收在 `OutputNaming.ext` 里 ——
            // 完成后定位那一侧用的是同一个函数，两边必须同源。避让的判据要带上
            // 它：目录里躺着一个同名主干的 mp4 时，仅音频的新任务不该被改成 `T (2)`。
            guard let stem = OutputNaming.availableStem(
                base,
                ext: OutputNaming.ext(audioOnly: audioOnly),
                taken: taken,
                existingNames: existingNames
            ) else {
                failures.append(SubmissionFailure(
                    page: page,
                    reason: "同名文件太多（加到 (999) 还是撞名），先把下载目录里同名的清一清。",
                    guidance: nil
                ))
                continue
            }

            do {
                // audioOnly / downloadAPI 就按 TaskNewReq 里对应的那两个字段
                // （10 audio_only / 7 api_type）传下去，别落下。
                try await client.newTask(
                    aid: page.pageAv,
                    bvid: page.pageBv,
                    cid: page.pageCid,
                    quality: quality,
                    audio: audio,
                    codec: codec,
                    api: downloadAPI,
                    saveFilename: stem,
                    audioOnly: audioOnly
                )
            } catch let error as CoreError {
                failures.append(SubmissionFailure(
                    page: page, reason: error.description, guidance: error.guidance
                ))
                continue
            } catch {
                failures.append(SubmissionFailure(
                    page: page, reason: String(describing: error), guidance: nil
                ))
                continue
            }

            // **提交成功才占坑**：失败的任务不会产出文件，主干可以让给后面的
            // 分P；成功后必须立刻占住，否则同一批里的下一个同名分P 会算出
            // 同一个主干，而那时磁盘上还没文件可查（前一个任务在下载中）。
            //
            // 注意这一句在 `await` 之后才跑：它只保得住**本次调用内部**的先后，
            // 跨调用的重叠由函数入口的重入闸挡（见 `enqueue` 开头）。
            taken.insert(stem)
            reservedStems.insert(stem)
            pendingTitles[stem] = label
            created += 1
        }

        guard created > 0 else {
            parseError = Self.failureSummary(failures, total: pages.count)
            return
        }
        await refreshTasks()
        if failures.isEmpty {
            parseError = nil
            tab = .tasks
        } else {
            // 有失败就留在「下载」页：那几条汇总就显示在这里，切走了等于
            // 把用户看不见的失败藏起来。任务已经建起来了，去「任务」页
            // 随时能看到。
            parseError = Self.failureSummary(failures, total: pages.count)
        }
    }

    /// 这个分P 提交时用的标题。
    ///
    /// 多分P 带上 `P<序号> ` 前缀：只按分P 标题命名的话，两个分P 重名时
    /// 光看文件名分不出是哪个（超长截断之后更容易重名）。
    private static func taskLabel(
        for page: Jijidown_Core_BvideoPage,
        multiPart: Bool,
        video: Jijidown_Core_BvideoInfoReply?
    ) -> String {
        let raw = page.pageTitle.isEmpty ? (video?.displayTitle ?? "") : page.pageTitle
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = cleaned.isEmpty ? page.pageBv : cleaned
        return multiPart ? "P\(page.pageIndex) \(named)" : named
    }

    /// 批量提交失败时给用户的一段话。
    ///
    /// 分三层说：**整体**（几个里有几个没成）→ **逐项**（哪个分P、为什么）→
    /// **共同的下一步**。
    ///
    /// 最后一层有条件：只有整批都失败、且都是核心给的同一种错时，才把它那句
    /// 「下一步怎么办」当成整批的解释。混着本地错误时贴上去就是拿单个任务的
    /// 口径解释整批，只会误导。
    private static func failureSummary(_ failures: [SubmissionFailure], total: Int) -> String? {
        guard !failures.isEmpty else { return nil }

        let names = failures.map { "P\($0.page.pageIndex)" }.joined(separator: "、")
        var lines = ["\(total) 个分P 里有 \(failures.count) 个没建起来：\(names)"]
        lines.append(contentsOf: failures.map { "· P\($0.page.pageIndex)：\($0.reason)" })

        let guidances = Set(failures.compactMap(\.guidance))
        if failures.count == total, guidances.count == 1, let only = guidances.first {
            lines.append(only)
        } else if failures.contains(where: { $0.guidance == nil }) {
            lines.append("""
                上面没给出处的那几条是客户端本地就失败的，最常见的原因是**该分P \
                没有你选的清晰度或音质** —— 核心的 AllQuality 枚举接口调不动\
                （见「已知限制」），档位只能自己试，选了个该视频没有的档位就会这样。\
                换一个档位再试。
                """)
        }
        return lines.joined(separator: "\n")
    }

    /// 读下载目录里的文件名，**在主 actor 外面读**。
    private nonisolated static func fileNames(in directory: URL) async -> [String] {
        await Task.detached(priority: .utility) {
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        }.value
    }

    /// 任务对应的标题。
    ///
    /// 配对靠核心回显的 `task_title`（见 `claimNewTasks`），配不上就是空串 ——
    /// **不要退化成按列表顺序猜**，那配出来的是错名字。界面可以退回显示
    /// `task.taskTitle`（那是核心回显的文件主干名，本身是准的），再不行才用任务 id。
    func title(for taskID: String) -> String {
        taskTitles[taskID] ?? ""
    }

    /// 这个任务没在本地标题对照表里配上对（判据见 `claimNewTasks`）。
    ///
    /// **只说明「我们叫不出它的标题」，不说明产物找不到** —— 主干名来自核心
    /// 回显，配不上对也照样记，定位与「在访达中显示」都正常。任务的列表统计
    /// 用 `hasUnpairedTasks`，单独判某一行用这个。
    func isUnpaired(_ taskID: String) -> Bool {
        unpairedTaskIDs.contains(taskID)
    }

    /// 这个任务的产物落在哪。nil 表示还没下完、或者没定位到。
    func savedPath(for taskID: String) -> String? {
        savedPaths[taskID]
    }

    /// 这个任务的产物定位到哪一步了。
    ///
    /// **界面上的「在访达中显示」按钮（给不给、亮不亮）和它下面那行说明，都必须
    /// 从这一个答案派生。** 以前这两处各写各的判据：按钮看 `savedPath(for:) == nil`，
    /// 说明看 `hasGivenUpOutput(_:)` 再串一个 `taskStatus != .taskError`，于是
    /// 「出错、但 `complete_time > 0`」的任务两边都不认 —— 按钮灰着，旁边一句话
    /// 都没有，用户只知道点不动（`TaskListView` 里那句「『为什么点不动』还得靠
    /// 行内那行说明」的承诺当场落空）。
    ///
    /// 判据收在这里之后，两者不可能再分家：按钮灰（非 `.located`）就一定有说明。
    ///
    /// 三态的区别是「模型还找不找」：
    /// - `.searching`：还没判过，每 2 秒一次的刷新里都会再比对一次目录；
    /// - `.givenUp`：已经判过了（追了 30 秒没落盘就不再找），见 `gaveUpTaskIDs`。
    ///
    /// 只有下完的任务才可能走到后两态 —— 定位的候选本身就要求 `isFinished`。
    /// 反过来，没下完的任务一律是 `.searching`，但那时按钮根本不出现。
    enum OutputState: Equatable {
        case located
        case searching
        case givenUp
    }

    func outputState(_ taskID: String) -> OutputState {
        // 先判定位成功：放弃之后 `gaveUpTaskIDs` 里那一项也留着（不会移除），
        // 万一哪天又定位成功（主干名迟到、或者定位逻辑改了），这一行的说明
        // 会变成「没找到产物」这句**假话**，而文件夹按钮就在旁边亮着 ——
        // 这一问把那种情况挡在前面。
        if savedPaths[taskID] != nil { return .located }
        return gaveUpTaskIDs.contains(taskID) ? .givenUp : .searching
    }

    /// 在访达里显示**这个任务自己的**产物。
    ///
    /// 以前这里用的是「最近一次落盘的那一条」，于是点任何一行都跳到最新那个
    /// 下载，跟点哪一行无关 —— 一个既有毛病。
    func reveal(taskID: String) {
        guard let path = savedPaths[taskID] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 暂停 / 继续 / 删除任务。
    ///
    /// 失败**必须说出来**：这个方法末尾就 `refreshTasks()`，界面随即刷成核心
    /// 那边的真实状态，而失败时核心那边什么都没变 —— 用户看到的是「点了没反应」
    /// （详见 `taskActionError` 的说明）。老代码这里是一句 `try?`，错误连个出口
    /// 都没有，于是这件事连一句话都没留下。
    ///
    /// 成功则清掉上一次的错误：那句话说的是上一次操作，留着会让用户以为这一次
    /// 也没成。
    func control(_ taskID: String, _ action: Jijidown_Core_TaskDo) async {
        guard let client else {
            // 没连上核心时同样是「点了没反应」，所以也说出来 —— 这一支在用户
            // 眼里和被 `try?` 吞掉的那种失败没有区别。
            taskActionError = "「\(Self.actionLabel(action))」没能发出去：核心还没连上。"
            return
        }
        do {
            try await client.control(taskID: taskID, do: action)
            taskActionError = nil
        } catch let error as CoreError {
            // 正文 + `guidance` 一起给（和 `parse()` 一个路子）：只有一句错误码
            // 帮不到用户。两者是同一句话时不重复贴。
            let reason = error.guidance == error.description
                ? error.description
                : "\(error.description)\n\n\(error.guidance)"
            taskActionError = "对「\(displayTitle(for: taskID))」的「\(Self.actionLabel(action))」没有成功：\(reason)"
        } catch {
            taskActionError = "对「\(displayTitle(for: taskID))」的「\(Self.actionLabel(action))」没有成功：\(error)"
        }
        await refreshTasks()
    }

    /// 出错那句话里怎么称呼这个任务。
    ///
    /// 三段回退**和任务行显示标题用的是同一套判据**（见 `TaskRow.title`）：
    /// 用户得能拿这句话对上他刚点的那一行，对不上号的错误没什么用。
    private func displayTitle(for taskID: String) -> String {
        let known = title(for: taskID)
        if !known.isEmpty { return known }
        if let echoed = tasks.first(where: { $0.taskID == taskID })?.taskTitle,
           !echoed.isEmpty {
            return echoed
        }
        return "任务 \(taskID.prefix(8))"
    }

    /// 动作的中文名。**和 `Controls` 里的按钮文字逐字一致** —— 用户刚点的是
    /// 哪个按钮，错误里就得是同一个说法。
    private static func actionLabel(_ action: Jijidown_Core_TaskDo) -> String {
        switch action {
        case .nothing: "什么也不做"
        case .pause: "暂停"
        case .resume: "继续"
        case .delete: "仅删除任务"
        case .deleteAndFile: "删除任务和文件"
        case .UNRECOGNIZED(let raw): "未知操作(\(raw))"
        }
    }
}
