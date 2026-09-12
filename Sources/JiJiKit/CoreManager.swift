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
    /// 核心的 stdout/stderr，逐行追加。UI 的日志面板直接读它。
    public private(set) var log: [String] = []
    /// 最近一次校验到的核心版本（来自 hash 清单）。
    public private(set) var coreVersion: String = ""

    /// 下载目录。改动会落到 config.yaml。
    public var downloadDirectory: URL {
        didSet { if downloadDirectory != oldValue { rewriteConfig() } }
    }

    private var process: Process?
    private var logHandle: FileHandle?
    private var intentionalStop = false
    private var restartCount = 0

    // 这三个是纯路径常量，标 nonisolated —— 否则 `@MainActor` 会把它们也隔离起来，
    // 命令行探针这种非主 actor 的地方就读不到了。
    public nonisolated static let configDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/JiJiDown", isDirectory: true)
    public nonisolated static let installedBinary = configDirectory
        .appendingPathComponent("JiJiDownCore")
    public nonisolated static let configFile = configDirectory
        .appendingPathComponent("config.yaml")

    private static let maxLogLines = 2000
    private static let maxRestarts = 3

    public init() {
        let defaultDir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/JiJiDown", isDirectory: true)
        self.downloadDirectory = defaultDir
        self.logFileHandle = Self.openLogFile()
    }

    // MARK: - 生命周期

    /// 幂等地把核心准备好并启动。
    public func start() async {
        appendLog("[manager] start() 被调用，当前 phase=\(phase)")
        guard process == nil else {
            appendLog("[manager] 已有进程在跑，跳过")
            return
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
        do {
            try launch()
        } catch {
            appendLog("[manager] 启动核心失败：\(error)")
            phase = .failed("启动核心失败：\(error)")
            return
        }

        // 等端口真正可用再判定为 running —— 起进程成功 ≠ 服务可用。
        let ready = await waitForPort(timeout: 30)
        phase = ready ? .running : .failed("核心 30 秒内没有监听 \(CoreProtocol.defaultPort) 端口")
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
        // `max-task: 1` —— **不是随手写的，是为了不丢文件。** 核心给产物起的
        // 名字只由「清晰度/编码/音质/接口」四个角标决定，不含标题（见
        // `coreOutputName`）。两个同档位任务并行下载，就会在合并阶段写到
        // **同一个路径上互相覆盖**，后完成的把先完成的干掉 —— 实测就是这样
        // 丢了一个视频。串行执行 + 完成后立刻改名（`adoptOutput`），
        // 才能保证第二个任务落盘时那个文件名已经被腾空。
        let marker = "# 由唧唧客户端生成与维护；手工改过就会被保留，不再覆盖。"
        let yaml = """
        \(marker)
        log-level: info
        external-controller-port:
            grpc: \(CoreProtocol.defaultPort)
            grpc-web: 0
            restful-api: 64001
        user-info:
            access-token: ""
            refresh-token: ""
            cookies: ""
            raw-access-token: ""
            raw-cookies: ""
            hide-nickname: false
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
        // 只要文件存在且**没有我们写的标记**，就认定是用户手写的，保留不动。
        //
        // 早先的写法是「缺少某个字段就当成手写的」，那个判断很容易反过来咬人：
        // 用户手写一份完整配置（字段齐全）反而会被我们覆盖掉。
        if fm.fileExists(atPath: Self.configFile.path),
           let existing = try? String(contentsOf: Self.configFile, encoding: .utf8)
        {
            if !existing.contains(marker) {
                appendLog("[manager] 配置文件不是本客户端生成的，保留不覆盖")
                return
            }
        }
        try yaml.write(to: Self.configFile, atomically: true, encoding: .utf8)
    }

    // MARK: - 产物命名

    /// 把核心产出的那个「没名字」的文件按标题改名，返回最终路径。
    ///
    /// 逻辑本身在 `OutputNaming`（命令行探针也要用），这里只补一件事：
    /// 把改名结果写进托管日志，出问题时能从 manager.log 里查到。
    @discardableResult
    public func adoptOutput(coreName: String, title: String) -> URL? {
        let url = OutputNaming.adopt(in: downloadDirectory, coreName: coreName, title: title)
        if let url {
            appendLog("[manager] 产物改名 → \(url.lastPathComponent)")
        } else {
            appendLog("[manager] 产物改名失败：\(coreName)（文件不在或已存在同名）")
        }
        return url
    }

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
                self?.handleTermination(exitCode: proc.terminationStatus)
            }
        }

        try p.run()
        process = p
        appendLog("[manager] 核心已启动 pid=\(p.processIdentifier)")
    }

    private func handleTermination(exitCode: Int32) {
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
        appendLog("[manager] 核心意外退出（code \(exitCode)），第 \(restartCount) 次重启")
        phase = .starting
        Task {
            try? await Task.sleep(for: .seconds(1))
            await self.start()
        }
    }

    /// 轮询端口，确认核心真的开始服务了。
    private func waitForPort(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !(process?.isRunning ?? false) { return false }
            if Self.isPortOpen(port: UInt16(CoreProtocol.defaultPort)) {
                restartCount = 0
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
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
        let stamped = "[\(Self.stamp())] \(Self.strippingANSI(line))"
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
