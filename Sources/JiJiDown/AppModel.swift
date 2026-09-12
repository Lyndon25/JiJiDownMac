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
@MainActor
@Observable
final class AppModel {

    static let shared = AppModel()

    // MARK: 界面状态（本该是视图局部的 @State，见上面的说明）

    var tab: MainTab = MainTab.fromEnvironment
    var selectedPage: Jijidown_Core_BvideoPage?
    var audioOnly = false
    var autoScroll = true

    // 下载参数。默认 1080P / HEVC / WEB —— 这三个是实测最稳的组合。
    var quality: VideoQuality = .p1080
    var audio: AudioQuality = .q192K
    var codec: Jijidown_Core_VideoType = .hevc

    // MARK: 核心

    let core = CoreManager()
    private(set) var client: CoreClient?
    private(set) var serverName = ""
    private(set) var serverOS = ""

    // MARK: 登录

    var loginMethod: LoginMethod = .qr
    var loginAPI: Jijidown_Core_LoginQRCodeAPI = .tv
    var cookieInput = ""

    private(set) var qrPNG: Data?
    private(set) var qrIssuedAt: Date?
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

    // MARK: 用户与任务

    private(set) var user: Jijidown_Core_UserInfoReply?
    var isLoggedIn: Bool { user?.isLogin ?? false }
    private(set) var tasks: [Jijidown_Core_TaskStatusReply] = []
    /// 最近一次下载完成后的落盘路径，用来在界面上告诉用户文件去哪了。
    private(set) var lastSavedPaths: [String] = []

    // 任务与标题的配对（核心不给任务 id，也不填标题，只能客户端自己记）。
    private var claimedTaskIDs: Set<String> = []
    private var adoptedTaskIDs: Set<String> = []
    private var taskTitles: [String: String] = [:]
    private var unclaimedTitles: [String] = []

    // MARK: 解析

    private(set) var parsedVideo: Jijidown_Core_BvideoInfoReply?
    private(set) var qualities: Jijidown_Core_BvideoAllQualityReply?
    var input = ""
    private(set) var isParsing = false
    private(set) var parseError: String?

    private var pollTask: Task<Void, Never>?

    // MARK: - 核心启动

    func bootCore() async {
        await core.start()
        guard core.phase.isRunning else { return }
        await connect()
    }

    func shutdown() {
        pollTask?.cancel()
        loginTask?.cancel()
        core.stop()
        if let client { Task { await client.shutdown() } }
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
        // 传 0 取列表。遗留 proto 把 0 命名为 TASK_ALL，生效的那份命名为
        // taskError —— 语义待实测，见 CoreClient.listTasks 的说明。
        if let list = try? await client.listTasks(status: .taskError), !list.isEmpty {
            tasks = list
        } else {
            tasks = []
        }
        claimNewTasks()
        adoptFinishedTasks()
    }

    /// 把还没认领过的任务和排队中的标题配上对。
    ///
    /// 为什么要「认领」：`Task.New` 返回的是 `google.protobuf.Empty`，**核心不
    /// 告诉我们新建的任务 id**；而任务回复里的 `task_title` 又永远是空的
    /// （同一个根因，见 `CoreManager.coreOutputName`）。所以只能等任务出现在
    /// 列表里之后，按提交顺序把它和标题对起来。
    ///
    /// 配合 `max-task: 1`（见 `CoreManager.writeConfig`），同一时刻只会有一个
    /// 任务真正在跑，这个配对不会有歧义。
    private func claimNewTasks() {
        for task in tasks where !claimedTaskIDs.contains(task.taskID) {
            claimedTaskIDs.insert(task.taskID)
            guard !unclaimedTitles.isEmpty else { continue }
            taskTitles[task.taskID] = unclaimedTitles.removeFirst()
        }
    }

    /// 已完成的任务：把核心那个「没名字」的产物按标题改名。
    ///
    /// 必须在下载完成后做 —— 核心是合并阶段才把文件落盘的。
    private func adoptFinishedTasks() {
        for task in tasks where task.isFinished && !adoptedTaskIDs.contains(task.taskID) {
            adoptedTaskIDs.insert(task.taskID)
            let title = taskTitles[task.taskID] ?? ""
            if let url = core.adoptOutput(coreName: task.coreOutputName, title: title) {
                lastSavedPaths.append(url.path)
            }
        }
    }

    func refreshUser() async {
        guard let client else { return }
        user = try? await client.userInfo()
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

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        isLoggingIn = false
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
        guard let client else {
            loginError = "核心还没连上"
            return
        }
        let raw = cookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        let missing = Self.missingCookieFields(raw)
        guard missing.isEmpty else {
            loginError = "Cookie 里缺少这些字段：\(missing.joined(separator: "、"))"
            return
        }

        isImportingCookie = true
        loginError = nil
        defer { isImportingCookie = false }

        do {
            try await client.importCookie(cookies: raw)
            // 导入后立刻把输入框清掉 —— 凭据不该长时间留在界面上。
            cookieInput = ""
            loginStatusText = "已导入，正在确认…"
            try? await Task.sleep(for: .seconds(2))
            await refreshUser()
            if isLoggedIn {
                loginStatusText = "登录成功"
            } else {
                loginError = "核心接受了 Cookie 但用户信息仍是未登录，检查 Cookie 是否过期。"
            }
        } catch {
            loginError = "导入失败：\(error)"
        }
    }

    // MARK: - 解析

    func parse() async {
        guard let client else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isParsing = true
        parseError = nil
        parsedVideo = nil
        qualities = nil
        selectedPage = nil
        defer { isParsing = false }

        do {
            let check = try await client.checkContent(text)
            guard check.isValid else {
                parseError = "这个链接核心没认出来，检查一下 BV 号或地址。"
                return
            }
            let info = try await client.videoInfo(text)
            parsedVideo = info
            selectedPage = info.block.first?.list.first

            if let page = selectedPage {
                qualities = try? await client.allQuality(bvid: page.pageBv, cid: page.pageCid)
            }
        } catch let error as CoreError {
            // 最可能撞上的就是授权门 —— 把话说明白，别让用户以为是自己填错了。
            if case .functionNotAllowed = error {
                parseError = """
                    核心拒绝了这个功能。

                    核心的 license 模块把 GetVideoList / DownloadVideo 放在授权门后面。\
                    未登录时核心拿不到 access_token，也就换不到授权。

                    去「账号」页登录 B 站账号再试。
                    """
            } else {
                parseError = error.description
            }
        } catch {
            parseError = String(describing: error)
        }
    }

    // MARK: - 下载

    func enqueue(page: Jijidown_Core_BvideoPage) async {
        guard let client else { return }
        do {
            try await client.newTask(
                aid: page.pageAv,
                bvid: page.pageBv,
                cid: page.pageCid,
                quality: quality,
                audio: audio,
                codec: codec,
                api: .web,
                // 说明一下为什么这个参数是空的：**核心完全无视它**。
                // 实测传 "墨脱-1080P" 进去，产出照样是
                // ` (高清 1080P, HEVC, 极高音质, WEB).mp4`。
                // 文件名只能等下载完成后由 CoreManager.adoptOutput 补。
                saveFilename: ""
            )
            // 先把标题排进队列，等任务出现在列表里再认领（见 claimNewTasks）。
            unclaimedTitles.append(parsedVideo?.displayTitle ?? "")
            await refreshTasks()
            tab = .tasks
        } catch {
            parseError = """
                建任务失败：\(error)

                常见原因：这个视频没有你选的清晰度或音质。核心的 AllQuality \
                枚举接口是唧唧会员功能，非会员只能按标准 id 试 —— 换一个档位再试。
                """
        }
    }

    /// 任务对应的视频标题。
    ///
    /// 核心的 `task_title` 永远是空的（见 `CoreManager.coreOutputName` 的说明），
    /// 标题只能从我们自己的配对表里取。
    func title(for taskID: String) -> String {
        taskTitles[taskID] ?? ""
    }

    /// 在访达里显示最近一次下载的文件。
    func revealLastDownload() {
        guard let path = lastSavedPaths.last else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func control(_ taskID: String, _ action: Jijidown_Core_TaskDo) async {
        guard let client else { return }
        try? await client.control(taskID: taskID, do: action)
        await refreshTasks()
    }
}
