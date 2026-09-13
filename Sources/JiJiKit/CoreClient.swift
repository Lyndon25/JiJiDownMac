import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import JiJiProtos
import SwiftProtobuf

/// 与唧唧核心通信的协议常量。
public enum CoreProtocol {
    /// 核心只监听回环地址（它没有任何鉴权，绝不该暴露到网络上）。
    public static let defaultHost = "127.0.0.1"
    public static let defaultPort = 4000

    /// 核心对 `client_sdk` 做**白名单**校验，合法值只有三个 —— 直接从核心
    /// 二进制的字符串表里读出来的：
    ///
    ///     JiJiDownSwift/1.0.0
    ///     JiJiDownReact/1.0.0
    ///     JiJiDownCSharp/1.0.0
    ///
    /// 缺失该 metadata 会得到 `PERMISSION_DENIED: invalid request`；
    /// 值不在白名单里则是 `PERMISSION_DENIED: invalid client request`。
    /// 注意 `JiJiDownPython/1.0.0`（第三方 jithon 用的值）**已被拒绝**。
    ///
    /// 厂商把 `JiJiDownSwift` 放进白名单，说明 Swift 客户端是官方预期内的形态。
    static let clientSDK = "JiJiDownSwift/1.0.0"
}

/// 给每个请求注入 `client_sdk`。
///
/// 用拦截器而不是逐调用传参，是为了避免漏掉某个 RPC 时收到一个
/// 看起来毫不相关的 `PERMISSION_DENIED`。
struct ClientSDKInterceptor: ClientInterceptor {
    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (
            _ request: StreamingClientRequest<Input>,
            _ context: ClientContext
        ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        var request = request
        request.metadata.addString(CoreProtocol.clientSDK, forKey: "client_sdk")
        return try await next(request, context)
    }
}

/// 把核心返回的 gRPC 错误整理成上层能直接判断的形态。
public enum CoreError: Error, CustomStringConvertible {
    /// 核心没在跑（UNAVAILABLE）。
    case coreNotRunning
    /// 未登录（FAILED_PRECONDITION + "User no login"）。
    case notLoggedIn
    /// 核心说已经登录了（再调 LoginQRCode / ImportCookie 就会被它顶回来）。
    case alreadyLoggedIn
    /// 同一个视频、同样的参数已经有任务了。
    case taskExists
    /// 授权门：核心用 `<函数名> function not allowed` 拦人，且函数名在
    /// `authorizationGateFunctions` 名单里。
    ///
    /// 实测名单：`GetVideoList`、`DownloadVideo`、`DownloadBatch`。登录前必现，
    /// 登录后一般就通了 —— 核心需要拿登录换来的 access_token 去换授权，换到了
    /// 才放行。**所以这条出现时未必是「没登录」**，已登录还这样的话，是授权没换到。
    case needsAuthorization(String)
    /// 核心用 `It's a premium feature` 挡住的功能。
    ///
    /// 实测被它挡住的四个：`AllQuality`、`GetUpSpaceSeriesAndCollectionList`、
    /// `GetUPSubmitVideoList`、`GetFavoriteList`。厂商自己的客户端把这类
    /// 在日志里记作「无唧唧会员权限」。
    case premiumFeature(String)
    /// 核心明说 `function not allowed`，但函数名**不在**上面那张授权门名单里 ——
    /// 目前实测只有番剧（`GetBangumiList`）会这样，是没做，不是没权限。
    case notSupported(String)
    case rpc(code: String, message: String)

    public var description: String {
        switch self {
        case .coreNotRunning: "核心未运行"
        case .notLoggedIn: "未登录 B 站账号"
        case .alreadyLoggedIn: "核心说已经登录了"
        case .taskExists: "这个视频已经有同样的任务了"
        case .needsAuthorization(let m): "核心的授权门没放行（\(m)）"
        case .premiumFeature(let m): "核心尚未开放该功能（\(m)）"
        case .notSupported(let m): "核心不支持该功能（\(m)）"
        case .rpc(let code, let message): "\(code): \(message)"
        }
    }

    /// 给用户看的下一步建议。
    ///
    /// 比 `description` 长，只在界面上用。分开写是因为**光有一句错误码
    /// 帮不到用户**，而「去登录」这种建议如果在已登录时报出来，就是在骗人。
    public var guidance: String {
        switch self {
        case .coreNotRunning:
            "去「核心」页看看它为什么没起来。"
        case .notLoggedIn:
            """
            去「账号」页登录 B 站账号。

            核心拒绝的 GetVideoList / DownloadVideo 这两个接口，要拿到登录换来的 \
            access_token 才放行。
            """
        case .alreadyLoggedIn:
            "不用再登了，直接用就行。"
        case .taskExists:
            "去「任务」页看看，或者先把它删掉再重新提交。"
        case .needsAuthorization:
            """
            核心拦下了这个接口。它需要登录换来的 access_token 去换授权。

            如果你**还没登录**，去「账号」页登录即可。
            如果**已经登录了还这样**，说明授权没换到 —— 重新登录一次，
            或者去「核心」页看一眼日志里 [license] 那几行。
            """
        case .premiumFeature:
            """
            这个功能目前在核心那边调不动。官方路线图里，这类多半还标着「施工中」：
            番剧下载、字幕、收藏夹、up主投稿、互动视频、弹幕、批量下载、
            Hi-Res、订阅。

            换成单个视频的 BV 号就能下。
            """
        case .notSupported:
            "核心明确表示不做这个（比如番剧）。换普通视频的 BV 号来下。"
        case .rpc(let code, let message):
            "\(code): \(message)"
        }
    }

    /// 会被 `CoreError` 当成**授权门**的函数名（`<名字> function not allowed`）。
    ///
    /// 名单只收**实测过的**。`DownloadBatch` 是实测的（`failedPrecondition:
    /// DownloadBatch function not allowed`，与登录前的 `DownloadVideo` 同形），
    /// 所以归进这一支 —— 界面对它会说「回账号页看看」，而不是「核心明确表示
    /// 不做这个」。
    ///
    /// 同族应该还有 `DownloadAudio` / `DownloadBangumi` / `DownloadDanmaku`
    /// （官方路线图上那几个「施工中」的下载功能），但**没实测过**，所以不写进来：
    /// 判据宁可窄一点，也不能把「核心没做」说成「去登录」。
    private static let authorizationGateFunctions = [
        "GetVideoList", "DownloadVideo", "DownloadBatch",
    ]

    /// 从 `RPCError` 归类。
    ///
    /// 判据是**对着活核心实测出来的**，不是照 proto 猜的。核心用
    /// gRPC 状态码 + message 文本表达语义，几类错误的状态码还互相重叠，
    /// 所以只能靠 message 分辨，且顺序有讲究。
    static func from(_ error: any Error) -> CoreError {
        guard let rpc = error as? RPCError else {
            return .rpc(code: "LOCAL", message: String(describing: error))
        }
        let message = rpc.message

        // 先按 message 分辨 —— 这几类的状态码会撞车，靠码分不出来。
        if message.contains("premium feature") {
            return .premiumFeature(message)
        }
        if message.contains("already logged in") {
            return .alreadyLoggedIn
        }
        if message.contains("task already exists") {
            return .taskExists
        }
        if rpc.code == .unavailable {
            return .coreNotRunning
        }
        if message.contains("no login") {
            return .notLoggedIn
        }
        if message.contains("function not allowed") {
            // 同一个说法罩着两种完全不同的情况，必须按函数名分开：
            // 名单里的是授权门（登录换的 access_token 能解锁），
            // 其余（实测只有 GetBangumiList）是压根没做。
            let isAuthGate = Self.authorizationGateFunctions.contains { message.contains($0) }
            return isAuthGate ? .needsAuthorization(message) : .notSupported(message)
        }
        return .rpc(code: String(describing: rpc.code), message: message)
    }
}

/// 建一条任务要的一整组参数。
///
/// 存在的理由：`Task.New` 与 `Task.NewBatch` 的请求体是同一个 `TaskNewReq`，
/// 每个调用点各拼一遍字段迟早会拼岔（此前 proto 错位一位，正是所有调用点
/// 一起错）。所以字段只在 `CoreClient.makeNewReq` 里落一次，两个接口共用。
public struct TaskParams: Sendable {
    public var aid: Int64 = 0
    public var bvid: String = ""
    public var cid: Int64 = 0

    /// 清晰度 id，**原样**发给核心，不经过 `VideoQuality` 校验。
    ///
    /// 用枚举构造时自然是合法档位；要试「枚举里没有的 id」就走下面那个
    /// 原样 init。**别用 `VideoQuality(rawValue:) ?? .p1080` 兜底** ——
    /// 那会把越界值悄悄改写成 1080P，实验条件被改掉还不知道
    /// （上一轮实测正是因此白跑了一遍 1080P）。
    public var videoQuality: UInt32 = VideoQuality.p1080.rawValue

    /// 音质 id，同上，原样发给核心。
    public var audioQuality: UInt32 = AudioQuality.q192K.rawValue

    public var codec: Jijidown_Core_VideoType = .hevc
    public var api: DownloadAPI = .web

    /// 核心命名模板的**主干名**（`TaskNewReq.save_filename`，字段 9）。
    ///
    /// 实测语义（r339）：它填进核心命名模板的第一个 `%s`，也就是标题位，
    /// 产出 `<save_filename> (清晰度角标, 编码, 音质角标, 接口).<扩展名>`。
    /// 传空串时那一位就是空的，于是文件名以一个空格开头。
    ///
    /// 三个坑：
    /// - 扩展名由核心决定（视频永远 `.mp4`，仅音频永远 `.mp3`），带进去也没用：
    ///   传 `"标题.mp4"` 出来是 `"标题.mp4 (…).mp4"`，双扩展名。
    /// - 里面带 `/` 会让 ffmpeg 失败、任务转 `TASK_ERROR` 且**不产出文件**，
    ///   提交前必须过滤路径分隔符（`OutputNaming.sanitized` 就是干这个的）。
    /// - **不要指望它防覆盖**：核心遇到同名文件是**静默覆盖**的（不加 `(2)`、
    ///   不报错）。「绝不覆盖」只能由客户端保证，而且是**提交之前**保证
    ///   （`OutputNaming.availableStem` 拿目录里的现有文件名避让）——
    ///   等下载完再改名兜底就晚了，那时文件已经被盖掉了。
    public var saveFilename: String = ""

    /// 只下音频（`audio_only`，字段 10）。
    ///
    /// 实测：产物是 mp3（本次样本 253,067 字节，没有视频轨），并且
    /// `TaskStatusReply.audio_only` 会回显 true —— 这是个可用的判据。
    public var audioOnly: Bool = false

    /// 批量下载回调号（字段 11）。单条 `Task.New` 用不到它
    /// （`TaskNewBatchReply` 里只有 callback 和 err，没有任务 id），
    /// 留着是为了能复现那段历史观测。
    public var callback: UInt64 = 0

    public init(
        aid: Int64 = 0,
        bvid: String = "",
        cid: Int64 = 0,
        quality: VideoQuality = .p1080,
        audio: AudioQuality = .q192K,
        codec: Jijidown_Core_VideoType = .hevc,
        api: DownloadAPI = .web,
        saveFilename: String = "",
        audioOnly: Bool = false,
        callback: UInt64 = 0
    ) {
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.videoQuality = quality.rawValue
        self.audioQuality = audio.rawValue
        self.codec = codec
        self.api = api
        self.saveFilename = saveFilename
        self.audioOnly = audioOnly
        self.callback = callback
    }

    /// 清晰度 / 音质按 **id 原样**给的版本，供实测与「枚举里没有的档位」用。
    public init(
        aid: Int64 = 0,
        bvid: String = "",
        cid: Int64 = 0,
        videoQuality: UInt32,
        audioQuality: UInt32,
        codec: Jijidown_Core_VideoType = .hevc,
        api: DownloadAPI = .web,
        saveFilename: String = "",
        audioOnly: Bool = false,
        callback: UInt64 = 0
    ) {
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.videoQuality = videoQuality
        self.audioQuality = audioQuality
        self.codec = codec
        self.api = api
        self.saveFilename = saveFilename
        self.audioOnly = audioOnly
        self.callback = callback
    }
}

/// 唧唧核心的 gRPC 客户端。
///
/// 用 `actor` 保证并发安全；持有**长生命周期**连接（App 全程复用），
/// 因此不用 `withGRPCClient` 那种作用域式写法，而是自己跑 `runConnections()`
/// 并在 `shutdown()` 里优雅关闭。
public actor CoreClient {

    public typealias Transport = HTTP2ClientTransport.Posix

    private let client: GRPCClient<Transport>
    private var runTask: Task<Void, any Error>?

    /// - Parameters:
    ///   - host: 默认 `127.0.0.1`。核心无鉴权，不要指向别的机器。
    ///   - port: 默认 4000（native gRPC）。
    public init(host: String = CoreProtocol.defaultHost, port: Int = CoreProtocol.defaultPort) throws {
        // 用 .ipv4(address:) 而不是 .ipv4(host: "localhost") —— 后者把 "localhost"
        // 当 IPv4 字面量解析，会失败并报一个毫无线索的 "channel isn't ready"。
        let transport = try HTTP2ClientTransport.Posix(
            target: .ipv4(address: host, port: port),
            transportSecurity: .plaintext
        )
        self.client = GRPCClient(transport: transport, interceptors: [ClientSDKInterceptor()])
    }

    // MARK: 生命周期

    public func start() {
        guard runTask == nil else { return }
        let client = self.client
        runTask = Task { try await client.runConnections() }
    }

    public func shutdown() async {
        client.beginGracefulShutdown()
        _ = try? await runTask?.value
        runTask = nil
    }

    // MARK: service 门面（构造很轻，直接现取）

    private var status: Jijidown_Core_Status.Client<Transport> { .init(wrapping: client) }
    private var users: Jijidown_Core_User.Client<Transport> { .init(wrapping: client) }
    private var bvideo: Jijidown_Core_Bvideo.Client<Transport> { .init(wrapping: client) }
    private var tasks: Jijidown_Core_Task.Client<Transport> { .init(wrapping: client) }

    private func unary<M: Sendable>(_ message: M) -> ClientRequest<M> {
        ClientRequest(message: message)
    }

    // MARK: Status

    /// 连通性探测。返回核心自报的名字与所在系统。
    public func ping() async throws -> Jijidown_Core_StatusPingPong {
        let client = self.status
        do {
            return try await client.ping(request: unary(SwiftProtobuf.Google_Protobuf_Empty()))
        } catch {
            throw CoreError.from(error)
        }
    }

    /// 检查更新（服务端流）。
    ///
    /// 三件必须先知道的事：
    ///
    /// 1. 这是**核心启动时那次检查的回放，不是重新联网**。实测每次调用只回 1 条
    ///    （本机 status=1 NOTSUPPORTUPDATE + 195 字 changelog），反复调内容一模一样。
    /// 2. 尽管实测只有 1 条，它**仍然可能推多条**：`UpdateStatusType.CHECKING(0)`
    ///    本身就是「检查中 / 下载更新」两个含义合一，所以调用方得自己按 `status`
    ///    判断这条是进度还是结论，不能假定流里只有一条。
    /// 3. 我们**只读 `status` / `changeLog`，不做任何安装动作**（用户已经定了：
    ///    只提示，不下载不安装）。
    ///
    /// - Parameter timeout: 到点主动断流，默认 20 秒。加这道保险是因为
    ///   **核心关不关流是它的自由** —— 它要是不关，调用方的 `for try await`
    ///   会一直挂着，界面就永远停在「检查中」。到点按**正常结束**收尾，不抛错：
    ///   已经收到的回复仍然有效，核心没关流这件事不该被说成检查失败。
    public nonisolated func checkUpdate(
        timeout: Duration = .seconds(20)
    ) -> AsyncThrowingStream<Jijidown_Core_StatusCheckUpdateReply, any Error> {
        stream(timeout: timeout) { client, continuation in
            try await client.status.checkUpdate(
                request: ClientRequest(message: SwiftProtobuf.Google_Protobuf_Empty())
            ) { response in
                for try await message in response.messages {
                    continuation.yield(message)
                }
            }
        }
    }

    // MARK: User

    public func userInfo() async throws -> Jijidown_Core_UserInfoReply {
        let client = self.users
        do {
            return try await client.info(request: unary(SwiftProtobuf.Google_Protobuf_Empty()))
        } catch {
            throw CoreError.from(error)
        }
    }

    /// 取登录二维码。返回 PNG 字节与用于轮询的 uuid。
    ///
    /// - Parameter api: `.tv` 能同时登录 WEB/TV/APP 三个接口，清晰度选项比
    ///   纯 WEB 多，且部分视频能拿到 TV 无水印源。优先用它。
    public func loginQRCode(api: Jijidown_Core_LoginQRCodeAPI = .tv) async throws
        -> (png: Data, id: String)
    {
        let client = self.users
        var req = Jijidown_Core_UserLoginQRCodeReq()
        req.api = api
        do {
            let reply = try await client.loginQRCode(request: unary(req))
            return (reply.qrCode, reply.id)
        } catch {
            throw CoreError.from(error)
        }
    }

    /// 轮询登录状态（服务端流）。已登录时核心会让 `LoginQRCode` 直接报错，
    /// 所以调用方应先试 `loginQRCode`。
    public nonisolated func loginStatus(id: String) -> AsyncThrowingStream<
        Jijidown_Core_UserLoginStatusReply, any Error
    > {
        stream { client, continuation in
            var req = Jijidown_Core_UserLoginStatusReq()
            req.id = id
            try await client.users.loginStatus(request: ClientRequest(message: req)) { response in
                for try await message in response.messages {
                    continuation.yield(message)
                }
            }
        }
    }

    /// 直接导入 Cookie 登录（扫码之外的唯一另一种方式）。
    ///
    /// 核心要求 Cookie 串里至少含这几个字段（它自己会校验）：
    /// `DedeUserID`、`DedeUserID__ckMd5`、`SESSDATA`、`bili_jct`、`sid`、`buvid3`。
    ///
    /// - Parameters:
    ///   - cookies: 上面那串 Cookie。**这是用户的登录凭据**，只在明确知情同意下
    ///     使用，不要落盘、不要外发。
    ///   - accessToken: 官方客户端的 Cookie 导入界面写着它「用于登录 TV、APP 接口」。
    ///     **本项目未验证**：本机配到的是空的，而 TV / APP 接口目前一律在取播放
    ///     地址那一步失败（`API TV not allowed` / `API APP not allowed`）——
    ///     有 token 会不会通，没验过，别把它当成已证实的解法。
    ///
    ///     这里**故意不给默认值**（仓库里 `listTasks` 也是同样的理由）：
    ///     调用方要么明确传空串表示「没有」，要么真有一个 token ——
    ///     不该让它悄悄留空，回头以为传过了。
    public func importCookie(cookies: String, accessToken: String) async throws {
        let client = self.users
        var req = Jijidown_Core_UserImportCookieReq()
        req.cookies = cookies
        req.accessToken = accessToken
        do {
            _ = try await client.importCookie(request: unary(req))
        } catch {
            throw CoreError.from(error)
        }
    }

    /// 任务完成推送（服务端流）。**目前 0 调用点。**
    ///
    /// App 走的是每 2 秒轮询 `Task.List`（见 `AppModel.refreshTasks`），没接这条
    /// 推送流 —— 这条流**实际能不能用没有验过**，所以留着的是「接口在这儿」这个
    /// 事实，而不是「它能用」的承诺。README 的「客户端没接」那一栏也是这个口径。
    ///
    /// 将来要接，先想清楚它和轮询的关系：轮询同时也在做别的事（认领新任务、
    /// 定位产物），换掉轮询不是删掉一个循环那么简单。
    public nonisolated func notifications() -> AsyncThrowingStream<
        Jijidown_Core_TaskNotificationReply, any Error
    > {
        stream { client, continuation in
            try await client.tasks.notification(
                request: ClientRequest(message: SwiftProtobuf.Google_Protobuf_Empty())
            ) { response in
                for try await message in response.messages {
                    continuation.yield(message)
                }
            }
        }
    }

    // MARK: Bvideo

    /// 校验一段输入（链接 / BV 号 / av 号）是否是有效视频。
    public func checkContent(_ content: String) async throws -> Jijidown_Core_BvideoCheckContentReply {
        let client = self.bvideo
        var req = Jijidown_Core_BvideoContentReq()
        req.content = content
        do {
            return try await client.checkContent(request: unary(req))
        } catch {
            throw CoreError.from(error)
        }
    }

    /// 取视频详情（标题、封面、UP 主、分P 列表）。
    ///
    /// 实测在未授权状态下核心会返回 `ABORTED: GetVideoList function not allowed`，
    /// 那是 license 模块的 Premium 门，不是参数问题。
    public func videoInfo(_ content: String) async throws -> Jijidown_Core_BvideoInfoReply {
        let client = self.bvideo
        var req = Jijidown_Core_BvideoContentReq()
        req.content = content
        do {
            return try await client.info(request: unary(req))
        } catch {
            throw CoreError.from(error)
        }
    }

    /// 列出该视频所有可下载的清晰度，按来源接口（WEB/TV/APP）分组。
    public func allQuality(aid: Int64 = 0, bvid: String = "", cid: Int64) async throws
        -> Jijidown_Core_BvideoAllQualityReply
    {
        let client = self.bvideo
        var req = Jijidown_Core_BvideoAllQualityReq()
        req.aid = aid
        req.bvid = bvid
        req.cid = cid
        do {
            return try await client.allQuality(request: unary(req))
        } catch {
            throw CoreError.from(error)
        }
    }

    // MARK: Task

    /// 建下载任务（单条，走 `Task.New`）。
    ///
    /// - Parameters:
    ///   - quality: 清晰度。默认 1080P。杜比视界传 `.dolbyVision`（实测可行，
    ///     47 分钟的片子约 4.5 GiB）。核心的 `AllQuality` 是会员接口，所以
    ///     非会员只能按标准 id 试；清晰度不存在时核心会干净报错
    ///     `expected video quality 'X', got 'Y'`。
    ///   - audio: 音质。默认 192K。全景声（`.dolbyAtmos`）只在有该音轨的片子上可用。
    ///   - codec: 编码。**默认 HEVC，绝不能传 `.unknown`** —— 核心按编码过滤，
    ///     UNKNOWN 匹配不到任何流，拿到空列表后在 `jdm.NewSession` 里
    ///     `index out of range` **直接 panic 退出整个核心**（实测）。
    ///   - saveFilename: 命名模板的**主干名**，见 `TaskParams.saveFilename`
    ///     （核心会自己在后面补角标与扩展名）。
    ///   - audioOnly: 只下音频，产物是 mp3，见 `TaskParams.audioOnly`。
    ///   - callback: 批量下载回调号，单条任务用不到，默认 0。
    public func newTask(
        aid: Int64 = 0,
        bvid: String = "",
        cid: Int64,
        quality: VideoQuality = .p1080,
        audio: AudioQuality = .q192K,
        codec: Jijidown_Core_VideoType = .hevc,
        api: DownloadAPI = .web,
        saveFilename: String = "",
        audioOnly: Bool = false,
        callback: UInt64 = 0
    ) async throws {
        try await newTask(
            TaskParams(
                aid: aid,
                bvid: bvid,
                cid: cid,
                quality: quality,
                audio: audio,
                codec: codec,
                api: api,
                saveFilename: saveFilename,
                audioOnly: audioOnly,
                callback: callback
            )
        )
    }

    /// 建下载任务，参数整组给定（清晰度 / 音质可以是不在枚举里的 id）。
    public func newTask(_ params: TaskParams) async throws {
        let client = self.tasks
        do {
            _ = try await client.new(request: unary(makeNewReq(params)))
        } catch {
            throw CoreError.from(error)
        }
    }

    /// 批量建任务（走 `Task.NewBatch`）。
    ///
    /// ⚠️ **目前这条路走不通，客户端不要依赖它。** 实测核心用授权门把它挡死了：
    ///
    ///     failedPrecondition: DownloadBatch function not allowed
    ///
    /// 与登录前的 `DownloadVideo function not allowed` 同形，所以 `CoreError.from`
    /// 把它归到 `.needsAuthorization`（界面会说「回账号页看看」，而不是
    /// 「核心明确表示不做这个」）。**批量下载的实现方式是逐条 `Task.New`**
    /// （多选分P → 逐条提交），不是这个接口。
    ///
    /// 返回的 `TaskNewBatchReply` 里**没有任务 id**，每条 `TaskCreationStatus`
    /// 只有 `callback` 和 `err` 两个字段 —— 就算它哪天放行了，调用方也只能靠
    /// 自己塞进去的 callback 配对。留着这个方法的理由就是随时能复验那道门。
    public func newTasks(_ params: [TaskParams]) async throws -> Jijidown_Core_TaskNewBatchReply {
        let client = self.tasks
        var req = Jijidown_Core_TaskNewBatchReq()
        req.newTasks = try params.map(makeNewReq)
        do {
            return try await client.newBatch(request: unary(req))
        } catch {
            throw CoreError.from(error)
        }
    }

    /// 把友好参数落成 `TaskNewReq`。
    ///
    /// **字段号只在这个函数里出现一次** —— `Task.New` 与 `Task.NewBatch` 共用它。
    private func makeNewReq(_ params: TaskParams) throws -> Jijidown_Core_TaskNewReq {
        // 兜一道：把「会崩核心」的取值挡在客户端，别指望服务端会拒绝。
        guard params.codec != .unknown else {
            throw CoreError.rpc(code: "INVALID_ARGUMENT", message: "video_codec 不能是 UNKNOWN，会导致核心崩溃")
        }

        var req = Jijidown_Core_TaskNewReq()
        req.aid = params.aid
        req.bvid = params.bvid
        req.cid = params.cid
        req.videoQuality = params.videoQuality
        req.audioQuality = params.audioQuality
        req.videoCodec = params.codec
        req.apiType = Jijidown_Core_ApiType(rawValue: Int(params.api.rawValue)) ?? .web
        // 显式写 .normal（普通投稿）。上游 proto 漏掉这个字段时，后面全部错位一位
        // —— 所以宁可明写，也不靠 proto 的默认值把话省掉。
        req.source = .normal
        req.saveFilename = params.saveFilename
        req.audioOnly = params.audioOnly
        req.callback = params.callback
        return req
    }

    /// 按状态列出任务。
    ///
    /// ⚠️ **过滤值 0 是「不过滤」，不是「只出错的任务」。**
    ///
    /// 这里有个真实的歧义：厂商仓库里 `TaskStatusType` 有**两份互相冲突的定义**，
    /// 遗留那份把 0 命名为 `TASK_ALL`，我们编译的这份把 0 命名为 `taskError`。
    /// 实测（r339）站遗留那份 —— **传 0 拿回来的是全部任务**，各种状态的都在
    /// 里面。也就是说同一个常量 0 在两个位置上含义完全不同：
    /// 当**过滤条件**是「全部」，当**任务自己的 `taskStatus`** 是「出错」。
    ///
    /// `.taskError` 这个名字读起来一点也不像「全部」，所以这里不给默认值，
    /// 强迫调用方显式选择；要「全部」请直接用 `listAllTasks()`。
    ///
    /// 另记一笔：枚举值 6（`taskComplete`）在实测中**从未出现过** ——
    /// 任务下完后状态停在 5。判完成请用 `TaskStatusReply.isFinished`。
    public func listTasks(status: Jijidown_Core_TaskStatusType) async throws
        -> [Jijidown_Core_TaskStatusReply]
    {
        let client = self.tasks
        var req = Jijidown_Core_TaskListReq()
        req.taskStatus = status
        do {
            return try await client.list(request: unary(req)).tasks
        } catch {
            throw CoreError.from(error)
        }
    }

    /// 列出**全部**任务（不论状态）。
    ///
    /// 内部就是 `Task.List` 传 0（0 = 不过滤，见 `listTasks` 的说明）。
    /// 单独开一个入口，是为了别让调用方为了表达「全部」去写 `.taskError` ——
    /// 那个名字放在过滤位置上，读的人会以为是「只列出错的任务」。
    public func listAllTasks() async throws -> [Jijidown_Core_TaskStatusReply] {
        try await listTasks(status: .taskError)
    }

    /// 单个任务的当前状态。
    public func taskStatus(taskID: String) async throws -> Jijidown_Core_TaskStatusReply {
        let client = self.tasks
        var req = Jijidown_Core_TaskStatusReq()
        req.taskID = taskID
        do {
            return try await client.status(request: unary(req))
        } catch {
            throw CoreError.from(error)
        }
    }

    /// 暂停 / 继续 / 删除任务。
    public func control(taskID: String, do action: Jijidown_Core_TaskDo) async throws {
        let client = self.tasks
        var req = Jijidown_Core_TaskControlReq()
        req.taskID = taskID
        req.do = action
        do {
            _ = try await client.control(request: unary(req))
        } catch {
            throw CoreError.from(error)
        }
    }
}

// MARK: - 流式调用桥接

extension CoreClient {
    /// 把「尾随闭包 + response.messages」式的 server-streaming 调用，
    /// 桥接成 `AsyncThrowingStream`，让 UI 层可以直接 `for try await`。
    ///
    /// - Parameter timeout: 非 nil 时到点主动断流。只有核心**可能不关流**的调用
    ///   才需要它（见 `checkUpdate`）：其余几条流是核心自己会收尾的。
    fileprivate nonisolated func stream<Message: Sendable>(
        timeout: Duration? = nil,
        _ body: @escaping @Sendable (
            _ client: CoreClient,
            _ continuation: AsyncThrowingStream<Message, any Error>.Continuation
        ) async throws -> Void
    ) -> AsyncThrowingStream<Message, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            try await body(self, continuation)
                            continuation.finish()
                        } catch {
                            // 超时那条已经把流收尾了，这里再补一个取消错误只会
                            // 把「正常超时」说成「流被中断」。
                            if Task.isCancelled { return }
                            continuation.finish(throwing: CoreError.from(error))
                        }
                    }
                    if let timeout {
                        group.addTask {
                            try? await Task.sleep(for: timeout)
                            continuation.finish()
                        }
                    }
                    // 谁先结束都算数：先结束的那个已经把流收尾，另一个取消掉。
                    // `finish()` 是幂等的，重复调用没有副作用。
                    await group.next()
                    group.cancelAll()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
