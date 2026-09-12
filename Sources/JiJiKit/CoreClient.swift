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
    /// 核心拒绝了这个功能：实测是 license 模块的 Premium 授权门
    /// （`license.(*license).GetVideoList` / `.DownloadVideo`）。
    case functionNotAllowed(String)
    case rpc(code: String, message: String)

    public var description: String {
        switch self {
        case .coreNotRunning: "核心未运行"
        case .notLoggedIn: "未登录 B 站账号"
        case .functionNotAllowed(let f): "核心拒绝该功能（需唧唧授权）：\(f)"
        case .rpc(let code, let message): "\(code): \(message)"
        }
    }

    /// 从 `RPCError` 归类。核心用 gRPC 状态码 + message 表达语义。
    static func from(_ error: any Error) -> CoreError {
        guard let rpc = error as? RPCError else {
            return .rpc(code: "LOCAL", message: String(describing: error))
        }
        let message = rpc.message
        switch rpc.code {
        case .unavailable:
            return .coreNotRunning
        case .failedPrecondition where message.contains("no login"):
            return .notLoggedIn
        case .aborted where message.contains("function not allowed"):
            return .functionNotAllowed(message)
        case .permissionDenied where message.contains("function not allowed"):
            return .functionNotAllowed(message)
        default:
            return .rpc(code: String(describing: rpc.code), message: message)
        }
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
    /// - Note: 这是**用户的登录凭据**。只在明确知情同意下使用，不要落盘、不要外发。
    public func importCookie(cookies: String, accessToken: String = "") async throws {
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

    /// 任务完成推送（服务端流）。
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

    /// 建下载任务。
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
    public func newTask(
        aid: Int64 = 0,
        bvid: String = "",
        cid: Int64,
        quality: VideoQuality = .p1080,
        audio: AudioQuality = .q192K,
        codec: Jijidown_Core_VideoType = .hevc,
        api: DownloadAPI = .web,
        saveFilename: String = "",
        audioOnly: Bool = false
    ) async throws {
        // 兜一道：把「会崩核心」的取值挡在客户端，别指望服务端会拒绝。
        guard codec != .unknown else {
            throw CoreError.rpc(code: "INVALID_ARGUMENT", message: "video_codec 不能是 UNKNOWN，会导致核心崩溃")
        }

        let client = self.tasks
        var req = Jijidown_Core_TaskNewReq()
        req.aid = aid
        req.bvid = bvid
        req.cid = cid
        req.videoQuality = quality.rawValue
        req.audioQuality = audio.rawValue
        req.videoCodec = codec
        req.apiType = Jijidown_Core_ApiType(rawValue: Int(api.rawValue)) ?? .web
        req.saveFilename = saveFilename
        req.audioOnly = audioOnly
        do {
            _ = try await client.new(request: unary(req))
        } catch {
            throw CoreError.from(error)
        }
    }

    /// 批量建任务。返回每个子任务的创建结果（含失败原因）。
    public func newTasks(_ requests: [Jijidown_Core_TaskNewReq]) async throws
        -> Jijidown_Core_TaskNewBatchReply
    {
        let client = self.tasks
        var req = Jijidown_Core_TaskNewBatchReq()
        req.newTasks = requests
        do {
            return try await client.newBatch(request: unary(req))
        } catch {
            throw CoreError.from(error)
        }
    }

    /// 按状态列出任务。
    ///
    /// 注意一个真实的歧义：厂商仓库里 `TaskStatusType` 有**两份互相冲突的定义**，
    /// 遗留那份把 0 命名为 `TASK_ALL`，生效那份（我们编译的）把 0 命名为
    /// `taskError`。所以「列出全部」到底怎么表达，proto 层面给不出答案 ——
    /// 传 0 是「全部」还是「仅错误」需要对着活的核心实测。
    /// 因此这里不做默认值，强迫调用方显式选择。
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
    fileprivate nonisolated func stream<Message: Sendable>(
        _ body: @escaping @Sendable (
            _ client: CoreClient,
            _ continuation: AsyncThrowingStream<Message, any Error>.Continuation
        ) async throws -> Void
    ) -> AsyncThrowingStream<Message, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(self, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: CoreError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
