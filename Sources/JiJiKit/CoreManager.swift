import CryptoKit
import Foundation
import Observation

/// 托管 JiJiDownCore 进程：安装 → 校验 → 写配置 → 启动 → 守护 → 收尾。
///
/// 设计要点：
/// - 核心是**闭源预编译二进制**，我们只负责把它放到正确位置并跑起来。
/// - 它没有任何鉴权，所以配置里强制只监听回环地址。
/// - App 退出时必须把它一起带走，否则会留下孤儿进程占着 4000 端口，
///   下次启动会因端口被占而失败（核心自己的报错是
///   "External controller gRPC listen error"）。
@MainActor
@Observable
public final class CoreManager {

    public enum Phase: Equatable, Sendable {
        case idle
        case preparing(String)
        case starting
        case running
        case stopped
        case failed(String)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    public private(set) var phase: Phase = .idle

    /// 核心进程**实际**还在不在跑。界面那颗「启动 / 停止核心」按钮的判据用它，
    /// **不要用 `phase.isRunning`**。
    ///
    /// 为什么两者必须分开看：它们会分家。等就绪超时（见 `start()` 的 `.timedOut`
    /// 分支）时 `phase` 是 `.failed`，而核心进程还活着 —— 界面若按 `phase` 判，
    /// 这颗按钮会显示成「启动核心」，点下去却在 `start()` 的幂等判据上早退，
    /// 于是**怎么点都没反应**，用户除了退出 App 没有第二条路。反过来也成立：
    /// 引用还在、进程其实已经没了（终止通知没送到的场合），这里如实给出 false，
    /// 按钮给出「启动核心」，`start()` 会把这个死引用清掉重建。
    public var isCoreProcessRunning: Bool { process?.isRunning ?? false }

    /// 核心的 stdout/stderr，逐行追加。UI 的日志面板直接读它。
    public private(set) var log: [String] = []
    /// 最近一次校验到的核心版本（来自 hash 清单）。
    public private(set) var coreVersion: String = ""

    /// 本次启动 `max-task: 1` 到底有没有真的落进 config.yaml。
    ///
    /// `nil` = 本次还没写过配置（核心没起来过），**无从判断**；
    /// `true` = 写进去了，核心按 1 个任务串行跑；
    /// `false` = 走了「config.yaml 已存在且没有旁路标记」那条早退分支，
    /// 一个字都没写，**没有串行这道屏障**。
    ///
    /// **为什么要把它摆出来。** 核心的并行度只由配置里这一项决定，而本客户端
    /// 有一条刻意不写配置的分支（见 `writeConfig`）。界面却要对用户承诺「这 N 个
    /// 分P 一个个依次进行，不会同时跑」—— 承诺之前必须问过这里，不能把
    /// 「配置里 max-task: 1」当成既定事实讲：那条分支上它压根没落地，用户提交
    /// 一批分P 后核心并行跑，撞名的产物会被**静默覆盖**，而界面全程保证不会。
    public private(set) var maxTaskApplied: Bool?

    /// 下载目录。改动会落到 config.yaml。
    ///
    /// 初值**从已有的 config.yaml 里读**（见 `downloadDirectoryFromConfig`），
    /// 读不到才退回 `~/Downloads/JiJiDown`。
    ///
    /// ⚠️ **现在没有改它的入口。** 界面（`CoreLogView` 的下载目录一行）是
    /// **只读展示**，全仓唯一的赋值点是 `init`（初始化期的赋值不触发 `didSet`），
    /// 所以下面的 `didSet` → `rewriteConfig()` 这条路跑得通、但一次都不会被触发。
    ///
    /// 将来要加「改下载目录」的入口，**先解决 `rewriteConfig` 注释里那件事**
    /// （改配置得重启核心，会把正在进行的下载全掐断），再动界面。
    public var downloadDirectory: URL {
        didSet { if downloadDirectory != oldValue { rewriteConfig() } }
    }

    private var process: Process?
    private var logHandle: FileHandle?
    private var intentionalStop = false
    private var restartCount = 0

    /// 本次启动已经命中的就绪标志（存标志原文，见 `readyLogMarkers`）。
    ///
    /// 每次启动前清空。不清就会拿着上一轮（甚至上一次启动）的日志把刚起来的
    /// 新进程判成「已就绪」—— 而它这时候连 license 都还没领。
    @ObservationIgnored private var seenReadyMarkers: Set<String> = []

    // 这三个是纯路径常量，标 nonisolated —— 否则 `@MainActor` 会把它们也隔离起来，
    // 命令行探针这种非主 actor 的地方就读不到了。
    public nonisolated static let configDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/JiJiDown", isDirectory: true)
    public nonisolated static let installedBinary = configDirectory
        .appendingPathComponent("JiJiDownCore")
    public nonisolated static let configFile = configDirectory
        .appendingPathComponent("config.yaml")

    /// 「这份 config.yaml 是本客户端写的」的标记 —— 一个**旁路文件**。
    ///
    /// 为什么不把标记写在 config.yaml 自己里面（上一版就是那么做的，写一行注释）：
    /// **核心会把这份配置重写一遍**（登录态写回时走 Go 的 `yaml.Marshal`，
    /// 它只序列化数据结构，注释一个都留不住）。本机那份就是证据：第一行直接是
    /// `log-level: info`，我们的注释没了，而 `access-token` / `cookies` 是核心
    /// 自己填进去的。
    /// 标记一丢，客户端就永远走「这是用户手写的，别动」那条分支 —— 结果是
    /// `max-task: 1`（防同档位产物互相覆盖的屏障）与下载目录再也落不了地。
    /// 核心不碰这个旁路文件，所以「是不是我们写的」从此是稳的。
    public nonisolated static let managedMarker = configDirectory
        .appendingPathComponent(".managed-by-client")

    private static let maxLogLines = 2000
    private static let maxRestarts = 3

    public init() {
        let fallback = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/JiJiDown", isDirectory: true)
        // 这里必须用**直接赋值**，而不是初始化完再调一个 setter：`downloadDirectory`
        // 带 didSet，赋值会触发 `rewriteConfig()` → 重启核心。初始化期的赋值不触发
        // didSet，正好避开那条连锁。见 `downloadDirectoryFromConfig`：为什么非读不可。
        let configured = Self.downloadDirectoryFromConfig()
        self.downloadDirectory = configured ?? fallback
        self.logFileHandle = Self.openLogFile()
        // 目录是从哪儿来的要留痕：它决定产物去哪个目录找，而找错目录是**静默**失败
        // （界面上只是「定位不到产物」，看不出是目录就不对）。
        appendLog("[manager] 下载目录 = \(downloadDirectory.path)（\(configured == nil ? "config.yaml 里读不到，用默认值" : "取自 config.yaml")）")
    }

    // MARK: - 生命周期

    /// 幂等地把核心准备好并启动。
    public func start() async {
        appendLog("[manager] start() 被调用，当前 phase=\(phase)")
        // 幂等判据是「进程**真的**还在跑」，不是「引用非 nil」。
        //
        // 老代码按引用判（`guard process == nil`），于是只要出现「phase 说失败、
        // 进程却还活着」（等就绪超时就是，见下面的 `.timedOut` 分支），之后每一次
        // start() 都在这里早退 —— 而界面那颗按钮按 phase 显示成「启动核心」，
        // 点它恰好就是调 start()：从此变成一个点多少次都毫无反应的空操作，
        // 用户只能退出 App。按「进程真的在跑」判，这个状态就还有出口。
        if let running = process, running.isRunning {
            appendLog("[manager] 已有进程在跑（pid \(running.processIdentifier)），跳过")
            return
        }
        if let dead = process {
            // 引用还在、进程已经没了。不清掉它，下面 `launch()` 只是把它盖写，
            // 而这个死引用在此之前会一直被当成「有核心在跑」—— 终止通知没送到
            // 的场合（phase 永远停在 .starting）就是这么来的，同样点不动。
            appendLog("[manager] 进程引用还在，但 pid \(dead.processIdentifier) 已经不在跑了，清掉它重新启动")
            logHandle?.readabilityHandler = nil
            logHandle = nil
            process = nil
        }
        intentionalStop = false

        do {
            try installIfNeeded()
        } catch {
            appendLog("[manager] 准备核心失败：\(error)")
            phase = .failed("准备核心失败：\(error)")
            return
        }
        do {
            try writeConfig()
        } catch {
            appendLog("[manager] 写配置失败：\(error)")
            phase = .failed("写配置失败：\(error)")
            return
        }

        phase = .starting
        reapStaleCore()
        // 清掉上一轮命中的标志，再把这个进程挂起来 —— 顺序不能反，
        // 否则刚起来的核心会继承上一轮的就绪判定。
        seenReadyMarkers.removeAll()
        do {
            try launch()
        } catch {
            appendLog("[manager] 启动核心失败：\(error)")
            phase = .failed("启动核心失败：\(error)")
            return
        }

        // 起进程成功 ≠ 服务可用，端口通了也还不够 —— 见 `readyLogMarkers`。
        switch await waitForReady(timeout: Self.readyTimeout) {
        case .ready:
            restartCount = 0
            appendLog("[manager] 核心就绪：端口在听，日志里也出现了启动完成的标志")
            phase = .running
        case .processExited:
            // 不下结论：交给 `handleTermination` —— 它才知道是不是我们主动停的、
            // 要不要重启、以及「端口被占 / 配置被拒」那几种具体说法。这里再报一次
            // 只会把它的结论盖掉。
            appendLog("[manager] 等就绪的过程中核心进程就退出了，交给终止处理")
        case .timedOut(let missing, let portOpen):
            let lack = missing.map(\.label).joined(separator: "、")
            let wanted = missing.map { "「\($0.text)」" }.joined(separator: "、")
            appendLog("""
                [manager] 等就绪超时（\(Int(Self.readyTimeout)) 秒）。端口\(portOpen ? "已通" : "还没通")，\
                但日志里没出现：\(lack)（要找的原文是 \(wanted)）。\
                实测端口一通不等于能用 —— 核心还要去领 license，在那之前发请求会被它顶回 \
                function not allowed，用户看到的就是莫名其妙的失败。\
                判据盯的是核心自己的日志文本（它没有别的「我准备好了」接口），所以换一版核心\
                改了措辞时这里会等不到：那种情况下以日志面板里的原文为准，别当成核心坏了。\
                核心多半卡在联网领 license（要访问 sabe.cc），看下面最后几行日志。
                """)
            // **刻意不在这里收掉进程。** 进程还活着说明核心还在跑（多半是卡在领
            // license），日志还在往外吐 —— 那是排查的唯一线索，而且万一只是我们
            // 盯的那句话没对上（换版核心改了措辞），收掉的是个本来好用的核心。
            //
            // 代价说清楚：这样就造出了「phase 说失败、进程还活着」这个状态。所以
            // 界面的判据必须是**进程**而不是 phase —— 那颗按钮这时给出的是
            // 「强制停止核心」（见 CoreLogView）：收掉它 → phase 落到 .stopped →
            // 再点就是一次真正的重新启动。
            //
            // 「下一步走哪条路」要写出来，而且得按当下进程还在不在分两种 ——
            // 在等就绪的这段时间里进程有可能已经退了（死引用还在，见 `start()`
            // 开头），那时按钮上写的就不是这两个字了。
            if let pid = process?.processIdentifier, isCoreProcessRunning {
                appendLog("""
                    [manager] 核心进程还留着（pid \(pid)），4000 端口仍被它占着，本客户端也不会去连它。\
                    要重来：在界面上点「强制停止核心」，等状态变成「已停止」再点「启动核心」。
                    """)
            } else {
                appendLog("[manager] 进程这时已经不在跑了（引用还是非 nil 的死引用）。界面那颗按钮是「启动核心」，点它会把死引用清掉、重新起一个。")
            }
            phase = .failed("核心 \(Int(Self.readyTimeout)) 秒内没就绪（缺：\(lack)）")
        }
    }

    public func stop() {
        intentionalStop = true
        logHandle?.readabilityHandler = nil
        logHandle = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        phase = .stopped
    }

    // MARK: - 安装与校验

    private func installIfNeeded() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)

        // 优先用 App bundle 里内嵌的那份；没有就要求用户自己装好。
        let resources = Bundle.main.resourceURL?.path ?? "(nil)"
        appendLog("[manager] Bundle.main.resourceURL = \(resources)")
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("JiJiDownCore"),
              fm.fileExists(atPath: bundled.path)
        else {
            guard fm.fileExists(atPath: Self.installedBinary.path) else {
                throw CoreManagerError.coreBinaryMissing
            }
            appendLog("[manager] 使用已安装的核心：\(Self.installedBinary.path)")
            return
        }

        phase = .preparing("校验核心")
        let expected = try expectedSHA256()
        appendLog("[manager] 期望 sha256 = \(expected.prefix(16))…  版本 \(coreVersion)")
        if fm.fileExists(atPath: Self.installedBinary.path),
           let existing = try? sha256(of: Self.installedBinary),
           existing == expected
        {
            appendLog("[manager] 核心已是目标版本（\(coreVersion)），跳过安装")
            return
        }

        phase = .preparing("安装核心")
        if fm.fileExists(atPath: Self.installedBinary.path) {
            try fm.removeItem(at: Self.installedBinary)
        }
        try fm.copyItem(at: bundled, to: Self.installedBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.installedBinary.path)

        let actual = try sha256(of: Self.installedBinary)
        guard actual == expected else {
            try? fm.removeItem(at: Self.installedBinary)
            throw CoreManagerError.checksumMismatch(expected: expected, actual: actual)
        }
        appendLog("[manager] 核心已安装并通过 sha256 校验（\(coreVersion)）")
    }

    /// 从随包的 hash 清单里取本机架构对应的期望值。
    private func expectedSHA256() throws -> String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("JiJiDownCore-hash.txt") else {
            appendLog("[manager] resourceURL 为 nil")
            throw CoreManagerError.hashManifestMissing
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        appendLog("[manager] 读清单 \(url.path) 存在=\(exists)")
        guard exists else { throw CoreManagerError.hashManifestMissing }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            appendLog("[manager] 清单不是合法 UTF-8，\(data.count) 字节")
            throw CoreManagerError.hashManifestMissing
        }

        // 清单是 CRLF 换行，格式 SHA256|version|filename。
        //
        // 坑：**不能用 `split(separator: "\n")`**。Swift 把 "\r\n" 视为
        // 一个 Character（扩展字形簇），按 "\n" 分割匹配不到任何东西，
        // 整个文件会被当成一行 —— 用 isNewline 才正确。
        let target = "JiJiDownCore-darwin-arm64"
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for line in lines {
            let parts = line.split(separator: "|").map(String.init)
            guard parts.count >= 3 else { continue }
            if parts[2] == target {
                coreVersion = parts[1]
                return parts[0]
            }
        }
        appendLog("[manager] 清单里没有 \(target)，共 \(lines.count) 行")
        throw CoreManagerError.hashManifestMissing
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 配置

    /// 从已有的 config.yaml 里读下载目录；读不到、没有这一项、值又为空串一律返回
    /// nil（由调用方决定退回什么）。
    ///
    /// **为什么非读不可。** `downloadDirectory` 不只是界面上那个展示值 ——
    /// 产物定位（`locateOutput`）拿它去目录里找文件。用户配置里的 download-dir
    /// 若不是默认值（换过官方客户端、或手工改过），而我们一直按默认值去找，
    /// 就会去错的目录里找，并且是**静默地**什么都找不到。
    ///
    /// **解析故意很朴素**：为一行配置引入 YAML 依赖不划算，因此照行首扫（与
    /// `JiJiProbe` 里那段同源）。两种写法都要吃：本客户端写出去的是带引号的
    /// （`download-dir: "/x"`），而核心用 Go 的 yaml.Marshal 重写这个文件时会
    /// 把引号去掉 —— 本机实测到的就是 `download-dir: /Users/…/JiJiDown`。
    /// 行尾注释**不剥离**，按字面当成路径的一部分；取第一处能读出值的匹配。
    ///
    /// 标 `nonisolated static`：和 `configFile` / `installedBinary` 一个道理 ——
    /// 主 actor 之外（命令行探针）也要能用。探针现在自己留了一份带
    /// `JJD_DOWNLOAD_DIR` 后门的实现，两者解析规则一致，改这里时记得对一眼。
    public nonisolated static func downloadDirectoryFromConfig() -> URL? {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else {
            return nil
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("download-dir:") else { continue }
            let value = trimmed
                .dropFirst("download-dir:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return URL(fileURLWithPath: value, isDirectory: true) }
        }
        return nil
    }

    /// 现有 config.yaml 里 `user-info` 那几个字段的**原样文本**（冒号后面那截，
    /// 带不带引号都照抄回去）。
    ///
    /// **为什么必须抄。** 核心会把登录态**写回** config.yaml —— 本机这份文件里的
    /// `access-token` / `cookies` 就是核心自己填的，而本客户端的配置模板里它们是
    /// 空串。我们既然从「几乎不再写」变成「每次启动都写」，不抄回去就等于每次启动
    /// 都把用户的登录态抹掉，那比原来那个 bug 更糟。
    ///
    /// 只抄模板里有的那几个 key，值不做 YAML 解析、也不重新转义 —— 重写一遍只会
    /// 多一个出错的机会（值里带引号、带 `:` 都可能被写坏）。
    private static let carriedUserInfoKeys = [
        "access-token", "refresh-token", "cookies",
        "raw-access-token", "raw-cookies", "hide-nickname",
    ]

    private static func existingUserInfo(in text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon])
            guard carriedUserInfoKeys.contains(key), out[key] == nil else { continue }
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { out[key] = value }
        }
        return out
    }

    /// `downloadDirectory` 变更后让 core 读到新配置。
    ///
    /// ⚠️ **现在没有入口，运行期一次都不会跑到这里。** 全仓唯一的赋值点在
    /// `init`，初始化期的赋值不触发 `didSet`；界面（`CoreLogView`）是只读展示。
    /// 也就是「改下载目录」这件事现在是**有代码、没入口**。留着是因为逻辑本身
    /// 是对的，等哪天加入口时能用上。
    ///
    /// **加入口之前必须先解决这件事：改配置只能靠重启核心生效，而重启会把
    /// 正在进行的下载全部掐断。** 核心不重载 config.yaml（见下面 `writeConfig`
    /// 那一段的说明），所以没有「热改」这条路可走；也就是说这个操作天然是
    /// 破坏性的，界面上要么禁止在有任务在跑时改，要么改之前把话说清楚。
    /// 不解决就接个输入框上去，用户点一下，几个下了一半的任务就没了。
    private func rewriteConfig() {
        guard process != nil else { return }
        // 直接改文件核心不会重载，必须重启才生效。
        appendLog("[manager] 下载目录已变更，重启核心以生效")
        stop()
        Task { await start() }
    }

    private func writeConfig() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)

        // 核心对缺失字段**不做兜底**：例如 session-workers 缺省会取 0，
        // 而它要求 1-3，结果是启动时直接 FATA 退出。所以每个字段都要写全。
        //
        // `max-task: 1` —— 不是随手写的。核心遇到同名文件是**静默覆盖**的，
        // 而「不覆盖」这道防线在客户端：提交前逐个避让撞名（`availableStem`），
        // 靠的是「上一次提交的主干已经被占掉」这个账算得准。并行下载会让
        // 同时有多个任务的产物往同一个目录里落，账面上看着不冲突的名字
        // （撞名后缀刚加上、文件还没落盘）也会真的撞上。串行 + 下载完就认领
        // （`locateOutput`），这个账才是确定的。
        //
        // 顺带一提，串行也让「提交顺序 = 完成顺序」这个直觉成立，界面上
        // 一批分P 下起来是挨个走完的。
        // 判据是**旁路标记文件**，不是 config.yaml 里的某一行注释：核心会把
        // 这个文件重写一遍，任何注释都留不住（见 `managedMarker`）。只有
        // 「config.yaml 本来就不存在」或「标记文件在」两种情况才写，其余一律
        // 认定是用户手写的，一个字都不动。
        let exists = fm.fileExists(atPath: Self.configFile.path)
        let ours = fm.fileExists(atPath: Self.managedMarker.path)
        guard !exists || ours else {
            // 「没写」这件事必须说清楚，而且要说清后果 —— 否则用户只会看到
            // 产物落在别的目录、界面上一片安静，完全不知道是这一步没做。
            appendLog("[manager] config.yaml 已存在，且没有旁路标记 \(Self.managedMarker.lastPathComponent)，当作是用户手写的配置，**刻意不写**（不覆盖它）")
            appendLog("[manager] 于是这两项这次没落地：下载目录 \(downloadDirectory.path)（产物会落到核心自己配置里的那个目录，界面按本客户端的目录去找就会找不到文件）、以及 max-task: 1（没有串行这道屏障，同档位的两个任务可能互相覆盖）。要让本客户端接管，把 \(Self.managedMarker.path) 建成一个空文件即可。")
            // 记下「没落地」。界面那句「会一个个依次进行」的承诺就靠这个判断 ——
            // 上面这些后果只写在日志里，用户看不到，界面再说成事实就是假的保证。
            maxTaskApplied = false
            return
        }

        // 沿用文件里已有的 user-info：核心把登录态写回在那里，重写时抹掉
        // 就等于每次启动都把用户登出。内容一律不打印。
        let carried = Self.existingUserInfo(
            in: (try? String(contentsOf: Self.configFile, encoding: .utf8)) ?? ""
        )
        let filled = carried.values.filter {
            !$0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).isEmpty
        }.count
        if filled > 0 {
            appendLog("[manager] 新配置沿用了现有 user-info 里的 \(filled) 个非空字段（不打内容）")
        }

        let yaml = """
        # 本文件由 JiJiDownMac 客户端写入；它是不是由本客户端维护，看同目录下有没有
        # \(Self.managedMarker.lastPathComponent) 这个文件 —— 注释会被核心重写掉，所以不用注释当标记。
        log-level: info
        external-controller-port:
            grpc: \(CoreProtocol.defaultPort)
            grpc-web: 0
            restful-api: 64001
        user-info:
            access-token: \(carried["access-token"] ?? "\"\"")
            refresh-token: \(carried["refresh-token"] ?? "\"\"")
            cookies: \(carried["cookies"] ?? "\"\"")
            raw-access-token: \(carried["raw-access-token"] ?? "\"\"")
            raw-cookies: \(carried["raw-cookies"] ?? "\"\"")
            hide-nickname: \(carried["hide-nickname"] ?? "false")
        download-task:
            temp-dir: ""
            download-dir: "\(downloadDirectory.path)"
            ffmpeg-path: ""
            max-task: 1
            download-speed-limit: 0
            disable-mcdn: false
        jdm:
            max-retry: 5
            retry-wait: 10
            session-workers: 1
            part-workers: 5
            min-split-size: 30
            proxy-addr: ""
            check-best-mirror: true
            cache-in-ram: false
            cache-in-ram-limit: 500
            insecure-skip-verify: false
            custom-root-certificates: ""
        """
        try yaml.write(to: Self.configFile, atomically: true, encoding: .utf8)
        // 写到这儿 max-task: 1 已经在文件里了，界面可以照实说「串行」。
        maxTaskApplied = true
        // 落下标记：从这一刻起这份配置归本客户端维护。内容为空即可 ——
        // 存在性就是全部信息。
        if !fm.createFile(atPath: Self.managedMarker.path, contents: nil) {
            appendLog("[manager] 写配置成功，但标记文件 \(Self.managedMarker.path) 没建成，下次可能就不写了")
        }
        appendLog("[manager] 已写 config.yaml（下载目录 \(downloadDirectory.path)，max-task 1）")
    }

    // MARK: - 产物定位

    /// 到下载目录里按主干名认领核心的产物，返回最终路径。
    ///
    /// 逻辑本身在 `OutputNaming`（命令行探针也要用），这里只补一件事：
    /// 把结果写进托管日志，出问题时能从 manager.log 里查到。
    ///
    /// - Parameter names: 调用方读好的目录清单。**不在这个方法里读目录** ——
    ///   读目录要碰磁盘，调用点（AppModel）全在主 actor 上，它自己知道该在
    ///   哪儿把这份清单读出来。
    ///
    /// 注意这里**只找、不改名**。核心产物的主干位就是提交时的 `save_filename`
    /// （见 `OutputNaming` 的类型说明），名字里已经有标题了，再改一次没有意义，
    /// 反而要多拼一次角标、多一次拼错的机会。
    ///
    /// **不负责「绝不覆盖」。** 核心遇到同名文件是静默覆盖的，那道防线整个在
    /// 提交这一侧（`OutputNaming.availableStem`）—— 认领阶段文件已经落盘了，
    /// 这时候做什么都晚了。
    @discardableResult
    /// - Parameter ext: 期望的产物扩展名，传 `OutputNaming.ext(audioOnly:)`。
    ///   **不能省**：主干同名、扩展名不同的两份产物是允许共存的（见 `matches`），
    ///   不筛扩展名会把另一种认成这个任务的产物。
    public func locateOutput(stem: String, among names: [String], ext: String) -> URL? {
        guard let name = OutputNaming.newestMatch(
            in: names, stem: stem, directory: downloadDirectory, ext: ext
        ) else {
            // 同一个主干只说一次。定位是跟着任务列表轮询每 2 秒调一遍的，一个
            // 下完却没落盘的任务能刷出十几条一模一样的话，把 manager.log 淹掉 ——
            // 「找不到」这件事说一遍和说十遍结论一样。
            if loggedMissingStems.insert(stem).inserted {
                appendLog("[manager] 下载目录里没有主干为「\(stem) (…」的产物（\(downloadDirectory.path)）")
                // 表别无限长。清空最多让某个主干再补一句，不会说错。
                if loggedMissingStems.count > 500 { loggedMissingStems.removeAll() }
            }
            return nil
        }
        appendLog("[manager] 产物 → \(name)")
        return downloadDirectory.appendingPathComponent(name)
    }

    /// 已经为哪个主干打过「找不到」的日志（见 `locateOutput`）。
    @ObservationIgnored private var loggedMissingStems: Set<String> = []

    // MARK: - 收尸

    /// 清掉占着端口的残留核心，给即将启动的进程腾位置。
    ///
    /// **为什么非要有这一步。** 核心是独立进程，App 被强退（`kill -9`）或崩溃时
    /// `applicationWillTerminate` 根本不会跑，它就一直占着 4000 端口 ——
    /// 下次启动直接失败，而核心只会报一句 `External controller gRPC listen error`，
    /// 对用户来说毫无线索。
    ///
    /// 核心自带一个 `-stop-with-process <PID>` 看起来正是干这个的，可惜实测
    /// （r339）**无效**：即便被盯的进程是它的父进程、且被 `kill -9`，核心照样
    /// 纹丝不动（手工隔离验证过，等了 90 秒也没退）。所以只能自己动手。
    ///
    /// 判据卡两道：**既要在监听我们的端口，可执行文件又必须正是我们安装的那份**。
    /// 两个都对上才动手 —— 避免误伤用户自己起的别的东西。
    private func reapStaleCore() {
        let port = UInt16(CoreProtocol.defaultPort)
        guard Self.isPortOpen(port: port) else { return }

        guard let pid = Self.pidListening(on: port) else {
            appendLog("[manager] 端口 \(port) 被占用，但查不出占用者是谁")
            return
        }
        guard Self.executablePath(ofPID: pid) == Self.installedBinary.path else {
            appendLog("[manager] 端口 \(port) 被 PID \(pid) 占用，但它不是本客户端安装的核心，不动它")
            return
        }

        appendLog("[manager] 发现残留的核心进程 PID \(pid)（上次没退干净），先收掉它")
        kill(pid, SIGTERM)
        for _ in 0..<20 {
            if !Self.isAlive(pid) { break }
            usleep(250_000)
        }
        if Self.isAlive(pid) {
            appendLog("[manager] PID \(pid) 不响应 SIGTERM，改用 SIGKILL")
            kill(pid, SIGKILL)
            usleep(500_000)
        }
        appendLog("[manager] 端口 \(port) 已腾空")
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// 谁在监听这个端口。`lsof -ti` 只输出 PID，一行一个。
    private static func pidListening(on port: UInt16) -> pid_t? {
        let out = run("/usr/sbin/lsof", ["-nP", "-ti", "tcp:\(port)", "-sTCP:LISTEN"])
        for line in out.split(whereSeparator: \.isNewline) {
            if let pid = pid_t(line.trimmingCharacters(in: .whitespaces)) { return pid }
        }
        return nil
    }

    /// 进程的可执行文件路径。
    ///
    /// `lsof -Fn` 的行是「字段标识 + 值」：`p<pid>`、`fcwd`、`n<路径>`…
    /// 要找的是 `ftxt` 后面紧跟的那条 `n`。
    private static func executablePath(ofPID pid: pid_t) -> String? {
        let out = run("/usr/sbin/lsof", ["-p", "\(pid)", "-Fn"])
        var expectingText = false
        for line in out.split(whereSeparator: \.isNewline) {
            if line == "ftxt" { expectingText = true; continue }
            if line.hasPrefix("f") { expectingText = false; continue }
            if expectingText, line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    /// 跑个外部命令把 stdout 收回来。查端口占用这点事儿不值得引 libproc。
    private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 进程

    private func launch() throws {
        let p = Process()
        p.executableURL = Self.installedBinary
        p.arguments = []
        p.currentDirectoryURL = Self.configDirectory

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        logHandle = pipe.fileHandleForReading

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    self?.appendLog(String(line))
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.handleTermination(proc)
            }
        }

        try p.run()
        process = p
        appendLog("[manager] 核心已启动 pid=\(p.processIdentifier)")
    }

    private func handleTermination(_ proc: Process) {
        // 先认进程：不是当下这一个就别动它。
        //
        // 终止通知是**异步**投到主 actor 上的，可能在它盯的那个进程死透之后才轮到
        // 执行；而 `start()` 现在允许「引用还在但进程已死」时清掉引用、重起一个
        // （见那里的幂等判据），于是这中间 `process` 可能已经换人。照单全收的后果
        // 很具体：把新进程的引用清掉、日志管道拆掉，还顺手去重启一次，最后两个核心
        // 抢 4000 端口，界面只看到一句 `listen error`。
        guard proc === process else { return }

        logHandle?.readabilityHandler = nil
        logHandle = nil
        process = nil

        if intentionalStop {
            phase = .stopped
            return
        }

        // 非预期退出。核心最常见的自爆原因是端口被占（多半是上一个
        // 没被收走的孤儿进程），那种情况下重启也没用，直接报清楚。
        let recent = log.suffix(20).joined(separator: "\n")
        if recent.contains("listen error") {
            phase = .failed("端口被占用。可能有一个残留的核心进程还在跑，先把它结束掉。")
            return
        }
        if recent.contains("Parse config error") {
            phase = .failed("核心拒绝配置文件：\(recent.split(separator: "\n").last.map(String.init) ?? "")")
            return
        }

        guard restartCount < Self.maxRestarts else {
            phase = .failed("核心连续退出 \(Self.maxRestarts) 次，不再重启")
            return
        }
        restartCount += 1
        appendLog("[manager] 核心意外退出（code \(proc.terminationStatus)），第 \(restartCount) 次重启")
        phase = .starting
        Task {
            try? await Task.sleep(for: .seconds(1))
            await self.start()
        }
    }

    /// 核心「真的能用了」的日志标志。
    ///
    /// **为什么不能只等端口。** 端口通了 ≠ 能用。实测（r339）本机一次启动：
    /// gRPC 端口在 28.667 就在 listening 了，而 `[license] Update License` 到
    /// 29.573、`JiJiDownCore Start Finish!` 到 30.171 才出现 —— 中间那一秒半里
    /// 发请求，需要授权的接口会被顶回 `function not allowed`（核心那条
    /// `User no login` 的 ERRO 也正是这段时间打出来的）。用户看到的就是
    /// 莫名其妙的失败。两句都出现才算就绪。
    ///
    /// **为什么会盯日志文本。** 核心没有提供「我准备好了」这类接口，日志是唯一
    /// 的信号。代价是它换了措辞我们就等不到 —— 所以判据只取两段短小、语义明确的
    /// 片段（不是整行匹配，行首的 `INFO[时间]` 与 `[main]` 前缀都不参与），
    /// 而且超时**不当成就绪**：明确失败，并把还缺哪一句写出来。
    ///
    /// label 只用于给用户看的短说法（`.failed` 那串会显示在核心页的标题行上，
    /// 太长会把那一行的按钮挤走），原文留给日志。
    private static let readyLogMarkers: [(label: String, text: String)] = [
        ("license 领取", "[license] Update License"),
        ("启动完成", "JiJiDownCore Start Finish!"),
    ]

    /// 等就绪的上限。核心本地启动一两秒就完事，剩下的是它去 sabe.cc 领 license
    /// 的网络时间 —— 留宽一点，但也不让用户对着「启动中」干等。
    private static let readyTimeout: TimeInterval = 60

    private enum Readiness {
        case ready
        /// 核心进程自己退了。这里不下结论，交给 `handleTermination`。
        case processExited
        /// 到点还没凑齐。带上缺哪句、端口通不通 —— 失败文案要用。
        case timedOut(missing: [(label: String, text: String)], portOpen: Bool)
    }

    /// 等核心真的可用：进程还在、端口在听、日志里两句标志都出现过。
    private func waitForReady(timeout: TimeInterval) async -> Readiness {
        func missingMarkers() -> [(label: String, text: String)] {
            Self.readyLogMarkers.filter { !seenReadyMarkers.contains($0.text) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !(process?.isRunning ?? false) { return .processExited }
            if missingMarkers().isEmpty,
               Self.isPortOpen(port: UInt16(CoreProtocol.defaultPort))
            {
                return .ready
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .timedOut(
            missing: missingMarkers(),
            portOpen: Self.isPortOpen(port: UInt16(CoreProtocol.defaultPort))
        )
    }

    /// 用一次真实 TCP 连接判断端口是否在监听。
    public static func isPortOpen(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // MARK: - 日志

    /// 核心的 stdout 带 ANSI 颜色码（`\e[36m` 之类），直接显示会变成
    /// 一串 `[36m` 字面量。UI 和日志文件都不需要颜色，统一剥掉。
    private static func strippingANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }

    private func appendLog(_ line: String) {
        let plain = Self.strippingANSI(line)

        // 核心启动时会画一个 ASCII 横幅，剥掉颜色码之后剩下的就是一堆纯空白行
        // （本机实测一次启动 36 行）。留着只能把真正的日志挤走。
        guard !plain.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        // 顺手核对就绪标志。放在这里而不是每轮去扫 `log` 数组：数组有 2000 行
        // 上限，标志行迟早会被裁掉；而且重启时旧日志还在，扫数组会把新进程
        // 误判成就绪。
        for marker in Self.readyLogMarkers where plain.contains(marker.text) {
            seenReadyMarkers.insert(marker.text)
        }

        let stamped = "[\(Self.stamp())] \(redact(plain))"
        log.append(stamped)
        if log.count > Self.maxLogLines {
            log.removeFirst(log.count - Self.maxLogLines)
        }
        // 同时落盘。UI 看不见的时候（比如启动阶段就失败）这是唯一的线索，
        // 用户报障时也能直接把这个文件发过来。
        if let handle = logFileHandle {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((stamped + "\n").utf8))
        }
    }

    // MARK: - 脱敏

    /// 登记一条不该出现在托管日志里的凭据（Cookie 串、access token 之类）。
    ///
    /// **为什么要有这张表。** 核心把请求内容原样打进 stdout，而 `appendLog`
    /// 是**逐行镜像**核心输出的 —— 不拦一手，凭据就同时进了内存里的日志面板
    /// 和 `manager.log` 这个文件。调用方（AppModel）在把凭据交给核心之前登记。
    ///
    /// 三条约束落在实现里：
    /// - **只在内存**：这张表不打印、不落盘，App 一退就没。命中时也只报一句
    ///   「隐去了一段」，不说是哪一条，更不打内容。
    /// - **空串不登记**：`replacingOccurrences(of: "")` 会把占位符塞进每个
    ///   字符之间，日志会变成一坨。
    /// - **太短的不登记**：三五个字符的「凭据」会在正常文本里到处命中，把无关
    ///   内容也替换掉，反而看不出原样。阈值与 AppModel 里那份 `redacting` 一致。
    public func registerSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minSecretLength else { return }
        guard !secrets.contains(trimmed), secrets.count < Self.maxSecrets else { return }
        secrets.append(trimmed)
    }

    private static let redactionPlaceholder = "＜已隐去＞"
    private static let minSecretLength = 8
    private static let maxSecrets = 16

    /// 把登记过的凭据替换成占位符。表是空的就直接返回，连一次字符串比较都不做。
    private func redact(_ text: String) -> String {
        guard !secrets.isEmpty else { return text }
        var out = text
        var hit = false
        for secret in secrets where out.contains(secret) {
            out = out.replacingOccurrences(of: secret, with: Self.redactionPlaceholder)
            hit = true
        }
        if hit, !didReportRedaction {
            didReportRedaction = true
            // 只说这一次。再往下就不再提醒 —— 一条流里同一段凭据可能被反复打印，
            // 每次都说反而成了噪音。（这一句本身也走 appendLog，但它不含凭据。）
            appendLog("[manager] 核心日志里出现了一段登记过的凭据文本，已替换成 \(Self.redactionPlaceholder)（只提醒这一次，内容不打印）")
        }
        return out
    }

    @ObservationIgnored private var secrets: [String] = []
    @ObservationIgnored private var didReportRedaction = false

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// 注意：`@Observable` 会把存储属性改写成计算属性，所以这里不能写 `lazy`，
    /// 必须在 init 里赋值，并用 @ObservationIgnored 让它不参与观察。
    @ObservationIgnored private var logFileHandle: FileHandle?

    private static func openLogFile() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let url = configDirectory.appendingPathComponent("manager.log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: url)
    }
}

public enum CoreManagerError: Error, CustomStringConvertible {
    case coreBinaryMissing
    case hashManifestMissing
    case checksumMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .coreBinaryMissing:
            "找不到核心二进制：App bundle 里没有内嵌，~/.config/JiJiDown/ 下也没有。"
        case .hashManifestMissing:
            "找不到或无法解析 JiJiDownCore-hash.txt"
        case .checksumMismatch(let expected, let actual):
            "核心 sha256 不匹配（期望 \(expected.prefix(16))…，实际 \(actual.prefix(16))…），已删除该文件"
        }
    }
}
