import Foundation
import JiJiKit
import JiJiProtos

// 命令行验证工具。子命令：
//   （无参数）        连通性与权限探针
//   status           登录状态
//   dl <BV号> [文件名] 走完整下载流程并轮询到结束
//   watch            实时盯任务列表

let args = Array(CommandLine.arguments.dropFirst())

/// 地址与下载目录都留一个环境变量后门。
///
/// 为什么需要：拿来做实验的那个核心通常跑在**另一个 HOME、另一个端口**上，
/// 免得跟 App 托管的那个抢端口、抢配置。核心是 Go 写的，认 `$HOME`
/// （实测用 `HOME=<临时目录>` 启动，它就去读那份配置了）；但 Foundation 的
/// `homeDirectoryForCurrentUser` 在 macOS 上**无视 `$HOME`**（走 getpwuid 拿
/// 真实家目录），所以下载目录没法跟着 HOME 走，只能单独给一个变量。
let env = ProcessInfo.processInfo.environment
let client = try CoreClient(
    host: env["JJD_HOST"] ?? CoreProtocol.defaultHost,
    port: env["JJD_PORT"].flatMap(Int.init) ?? CoreProtocol.defaultPort
)
await client.start()

// 收尾这件事**这里不做**，写清楚免得后人照抄一个不会发生的写法。
//
// 原来是一句 `defer { Task { await client.shutdown() } }`，它一次都执行不到：
// 下面各条路都是 `exit(0)` 直接终止进程，连 defer 都不进；自然结束那条路也一样 ——
// 顶层代码跑在 MainActor 上，这个没人 await 的 `Task { }` 要等主队列再被抽一次才
// 轮到，而顶层任务一返回，运行时就把进程退了。
//
// 也不打算为它把每条退出路径都改成 `await client.shutdown()` 再退：探针连的是
// **另外跑着的实验核心**（不是本进程托管的那个），进程一退操作系统就把套接字关了，
// 对端看到的是连接中断而不是 GOAWAY，与 App 退出那条路径一样。至于核心会不会为
// 这种硬断记一笔，没实测过，这里不下断言。

func h(_ t: String) { print("\n── \(t)") }

/// 一组建任务参数逐字段的样子，字段名照 `task.proto` 写，方便回头对账。
///
/// 为什么要专门打这个：参数是走 `TaskParams` 提交的，而实测最需要知道的是
/// 「**实际发出去的值**是什么」—— 比如清晰度，上一轮探针把它兜底成 1080P，
/// 打出来的却是实验意图，结论就错了一整轮。
///
/// `source` 直接写 0：它是 `CoreClient.makeNewReq` 里硬写的 `.normal`，
/// `TaskParams` 没给调用方留口子（番剧那条路走不通）。
func dumpParams(_ p: TaskParams) -> String {
    """
    aid=\(p.aid) bvid=\(p.bvid) cid=\(p.cid) \
    video_quality=\(p.videoQuality) audio_quality=\(p.audioQuality) \
    video_codec=\(p.codec.rawValue)(\(p.codec.label)) api_type=\(p.api.rawValue)(\(p.api.label)) \
    source=0(NORMAL) save_filename=\(p.saveFilename.isEmpty ? "＜空＞" : "\"\(p.saveFilename)\"") \
    audio_only=\(p.audioOnly) callback=\(p.callback)
    """
}

/// 清晰度 id 的中文名。认不出就如实说认不出。
///
/// 探针里**不做兜底**：`VideoQuality` 里没有的 id 原样发给核心，这里也只是
/// 打印时说明一句。兜底会把实验条件悄悄改掉。
func qualityNote(_ id: UInt32) -> String {
    VideoQuality(rawValue: id).map(\.label) ?? "＜VideoQuality 里没有这个 id，原样透传＞"
}

// MARK: - 下载并轮询到结束

/// 从 config.yaml 里读下载目录，读不到就用默认值。
///
/// 直接照着行首找 `download-dir:` —— 没必要为一行配置引入 YAML 解析。
func downloadDirectory() -> URL {
    // 环境变量优先。见文件顶部：实验用的核心被 HOME 重定向了，而 Foundation
    // 不认 HOME，读配置的方式绕不过去，只能由调用方显式指定。
    if let raw = env["JJD_DOWNLOAD_DIR"], !raw.isEmpty {
        return URL(fileURLWithPath: raw, isDirectory: true)
    }
    let fallback = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/JiJiDown", isDirectory: true)
    guard let text = try? String(contentsOf: CoreManager.configFile, encoding: .utf8) else {
        return fallback
    }
    for line in text.split(whereSeparator: \.isNewline) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("download-dir:") else { continue }
        let value = t.dropFirst("download-dir:".count)
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !value.isEmpty { return URL(fileURLWithPath: value, isDirectory: true) }
    }
    return fallback
}

/// 把任务回复的**每一个字段**原样打出来。
///
/// 为什么要这么啰嗦：光看见一句「下载完成」说明不了任何事 —— 状态停在哪个
/// 枚举值、`complete_time` 有没有填、`audio_only` 有没有回显，这些才是结论的
/// 依据。字段名一律照 proto 写，方便回头对账。
func dumpTask(_ t: Jijidown_Core_TaskStatusReply) {
    let p = t.progress
    print("   ── TaskStatusReply 全字段 ──")
    print("      task_id       = \(t.taskID)")
    print("      task_title    = \"\(t.taskTitle)\"")
    print("      video_badge   = \"\(t.videoBadge)\"")
    print("      audio_badge   = \"\(t.audioBadge)\"")
    print("      video_codec   = \"\(t.videoCodec)\"")
    print("      api_type      = \(t.apiType.rawValue) (\(t.apiType.label))")
    print("      audio_only    = \(t.audioOnly)")
    print("      task_status   = \(t.taskStatus.rawValue) (\(t.taskStatus.label))")
    print("      add_time      = \(t.addTime)")
    print("      complete_time = \(t.completeTime)")
    print("      save_path     = \"\(t.savePath)\"")
    print("      progress      = \(p.progress)%  \(p.completedLength)/\(p.totalLength)  \(p.downloadSpeed)  eta=\(p.eta)")
    print("      isFinished    = \(t.isFinished)")
}

/// 列出目录里每个文件的**原始**名字（一字不差，含前后空白）与大小。
///
/// 核心的产物名以一个空格开头，终端里肉眼很难分辨有没有那个空格，
/// 所以用 `"` 包起来、再把长度也打出来。
func listRaw(_ dir: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    if names.isEmpty {
        print("      （空目录）")
        return
    }
    for name in names.sorted() {
        let path = dir.appendingPathComponent(name).path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        print("      \"\(name)\"  (\(size ?? -1) 字节)")
    }
}

func download(
    bv: String,
    filename: String,
    /// 清晰度 id，**原样**发给核心。
    ///
    /// 这里收原始 id 而不是 `VideoQuality`，就是为了不再出现「认不出的值被
    /// 静默改写成 1080P」那件事 —— 上一轮实测正因此得出了错误结论。
    quality: UInt32,
    audio: AudioQuality = .q192K,
    codec: Jijidown_Core_VideoType = .hevc,
    audioOnly: Bool = false,
    noAdopt: Bool = false,
    /// `TaskNewReq.callback`，默认 0。
    ///
    /// 实测：清晰度取一个没有视频流的档位时，callback=0 会让取播放地址的那一步
    /// 报 20403 而失败，callback 非 0 才会走到「只有音频流」的路径上去。
    /// 这个现象现在有了解释 —— 此前 proto 错位一位，核心把 callback 读成了
    /// `audio_only`（见 task.proto），非 0 即「仅下载音频」，所以才只出音频。
    /// 字段订正后这里仍保留，是为了继续能复现/对照那段历史观测。
    callback: UInt64 = 0
) async {
    h("解析 \(bv)")
    let check: Jijidown_Core_BvideoCheckContentReply
    do {
        check = try await client.checkContent(bv)
        print("   有效=\(check.isValid)  id=\(check.blinkResult.id)  mark=\(check.blinkResult.mark)")
    } catch {
        print("   ❌ \(error)")
        return
    }
    guard check.isValid else { return }

    var cid: Int64 = 0
    var aid: Int64 = check.blinkResult.id
    var title = ""
    do {
        let info = try await client.videoInfo(bv)
        title = info.displayTitle
        print("   ✅ 标题: \(title)")
        print("      UP: \(info.upName)   分P: \(info.block.flatMap(\.list).count)")
        if let p = info.block.first?.list.first {
            cid = p.pageCid
            if p.pageAv != 0 { aid = p.pageAv }
        }
    } catch {
        print("   ⚠️  取详情失败: \(error)")
        print("      （若为“核心拒绝该功能”，说明仍未获得授权）")
        return
    }

    guard cid != 0 else { print("   ❌ 没拿到 cid，无法建任务"); return }

    h("建任务")
    // 核心不给任务 id（`Task.New` 返回 `Empty`），只能先记下现有的任务，
    // 再按「新冒出来的那个」认领自己的任务。
    let before = Set((try? await client.listAllTasks())?.map(\.taskID) ?? [])
    let params = TaskParams(
        aid: aid, bvid: bv, cid: cid,
        videoQuality: quality,
        audioQuality: audio.rawValue,
        codec: codec,
        api: .web,
        saveFilename: filename,
        audioOnly: audioOnly,
        callback: callback
    )
    do {
        try await client.newTask(params)
        print("   ✅ 已提交：\(dumpParams(params))")
        print("      清晰度 \(quality) 是 \(qualityNote(quality))")
    } catch {
        print("   ❌ \(error)")
        return
    }

    var mine: Jijidown_Core_TaskStatusReply?
    for _ in 0..<40 {
        try? await Task.sleep(for: .seconds(1))
        let now = (try? await client.listAllTasks()) ?? []
        if let t = now.first(where: { !before.contains($0.taskID) }) {
            mine = t
            break
        }
    }
    guard let task = mine else {
        print("   ❌ 40 秒内没等到任务出现在列表里")
        return
    }
    let taskID = task.taskID
    // 角标在任务创建时就定了，之后不会变，所以这时算出的文件名就是核心会用的那个。
    // 传了 save_filename 的话，它占着命名模板的主干位，得算进去。
    let coreName = OutputNaming.coreName(
        videoBadge: task.videoBadge,
        codec: task.videoCodec,
        audioBadge: task.audioBadge,
        api: task.apiType.label,
        saveFilename: filename,
        // 扩展名由核心按「是否仅音频」自己定：仅音频一律 .mp3，视频一律 .mp4。
        // 不传的话默认是 mp4，仅音频那次复验会拿一个根本不存在的 .mp4 去对目录，
        // 把一次成功的下载报成「对不上」，反而让人怀疑 save_filename 的结论。
        ext: audioOnly ? "mp3" : "mp4"
    )
    print("   任务 id=\(taskID.prefix(12))…  核心产物名=\(coreName)")
    print("      （这对不上就说明核心对 save_filename 的处理跟我们猜的不一样，"
        + "以目录里的实际文件名为准）")

    h("轮询进度（最多 30 分钟）")
    let deadline = Date().addingTimeInterval(1800)
    var lastLine = ""
    while Date() < deadline {
        try? await Task.sleep(for: .seconds(3))
        guard let tasks = try? await client.listAllTasks(),
              let t = tasks.first(where: { $0.taskID == taskID })
        else { continue }

        let p = t.progress
        let line = "\(t.displayLabel)  \(p.progress)%  \(p.downloadSpeed)  ETA \(p.eta)  \(p.completedLength)/\(p.totalLength)"
        if line != lastLine {
            print("   \(line)")
            lastLine = line
        }

        // 判据是 `isFinished`（completeTime 非 0），不是 `taskStatus == .taskComplete`
        // —— 核心下完后状态停在 GENMUSIC，等号右边永远不成立。
        if t.taskStatus == .taskError {
            print("   ❌ 任务出错")
            return
        }
        guard t.isFinished else { continue }

        print("   ✅ 下载完成")
        dumpTask(t)
        // 核心在合并阶段才落盘，这时文件才存在。
        let dir = downloadDirectory()
        print("   ── 落盘目录 \(dir.path) 的真实内容（改名之前）──")
        listRaw(dir)

        // 做实验时用 JJD_NO_ADOPT=1 跳过改名：留着核心的原名才是硬证据，
        // 改完名就分不清哪一段是核心起的、哪一段是我们加的了。
        if noAdopt {
            print("   （按 JJD_NO_ADOPT 要求跳过改名）")
            return
        }
        // 传了 save_filename 的场合：核心产物的主干名已经是它，名字本身就是
        // 想要的那个，再按标题加一遍前缀只会变成「标题+它」。所以直接收工。
        if !filename.isEmpty {
            print("   （本次传了 save_filename，核心产物名里已经有它，跳过改名）")
            return
        }
        // 本次没传 save_filename，主干位是空的，没有主干可以拿来定位 ——
        // 只能按上面拼出来的那个全名去目录里对。对不上就以目录里的实际
        // 文件名为准（角标本来就可能对不上，见 OutputNaming 的类型说明）。
        let expected = dir.appendingPathComponent(coreName)
        if FileManager.default.fileExists(atPath: expected.path) {
            print("      文件: \(expected.path)")
        } else {
            print("      ⚠️  没找到 \(coreName)（在 \(dir.path)），以上面的真实文件名为准")
        }
        return
    }
    print("   ⏱ 超时")
}

/// 高频追踪一条任务的状态**原始整数值**。
///
/// 与 `download()` 的关键区别：这里不打印本地 `TaskStatusType.label`，只出
/// `taskStatus.rawValue`。理由是仓库里的枚举定义与核心实际的枚举可能整体错位，
/// 拿错位的名字去描述观测值等于把结论预先污染掉。
///
/// 采样节奏也刻意不同：默认 **0.3 秒**一次，而正常下载只要几秒就跑完，
/// 所以中间态（等待 / 运行 / 合并）必须靠这个密度才抓得到。
func trace(
    bv: String,
    rawQuality: UInt32,
    codec: Jijidown_Core_VideoType,
    api: DownloadAPI
) async {
    let intervalMs = env["JJD_TRACE_MS"].flatMap(Int.init) ?? 300
    let maxSeconds = env["JJD_TRACE_MAX"].flatMap(Double.init) ?? 180
    let stableNeeded = env["JJD_TRACE_STABLE"].flatMap(Int.init) ?? 5

    h("解析 \(bv)")
    var cid: Int64 = 0
    var aid: Int64 = 0
    let check: Jijidown_Core_BvideoCheckContentReply
    do {
        check = try await client.checkContent(bv)
        aid = check.blinkResult.id
        print("   有效=\(check.isValid) aid=\(aid)")
    } catch {
        print("   ❌ CheckContent: \(error)")
        return
    }
    guard check.isValid else { print("   ❌ 无效稿件"); return }
    do {
        let info = try await client.videoInfo(bv)
        print("   ✅ 标题: \(info.displayTitle)")
        if let p = info.block.first?.list.first {
            cid = p.pageCid
            if p.pageAv != 0 { aid = p.pageAv }
        }
    } catch {
        print("   ❌ VideoInfo: \(error)")
        return
    }
    guard cid != 0 else { print("   ❌ 没拿到 cid"); return }

    let before = Set(((try? await client.listAllTasks()) ?? []).map(\.taskID))

    h("建任务（Task.New，清晰度原样=\(rawQuality) 编码=\(codec.label) 接口=\(api.label)）")
    let params = TaskParams(
        aid: aid, bvid: bv, cid: cid,
        videoQuality: rawQuality,
        audioQuality: AudioQuality.q192K.rawValue,
        codec: codec,
        api: api
    )
    do {
        try await client.newTask(params)
        print("   ✅ 已提交：\(dumpParams(params))")
    } catch {
        print("   ❌ 提交失败: \(error)")
        return
    }

    // 认领任务：核心不给 id，只能等新 id 冒出来。
    var taskID: String?
    for _ in 0..<40 {
        try? await Task.sleep(for: .milliseconds(intervalMs))
        let now = (try? await client.listAllTasks()) ?? []
        if let t = now.first(where: { !before.contains($0.taskID) }) { taskID = t.taskID; break }
    }
    guard let tid = taskID else { print("   ❌ 没等到任务出现在列表里"); return }
    print("   任务 id=\(tid)")

    h("开始高频采样（间隔 \(intervalMs)ms，连续 \(stableNeeded) 次不变算稳定，上限 \(maxSeconds) 秒）")
    print("   [时刻] status_raw | progress | complete_time | 标题/路径")
    // 绝对时刻（带毫秒）—— 核心日志的时间戳只到秒，靠它才能把采样点与
    // 「下载中 / 合并 / 完成」这些日志动作对上。
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss.SSS"
    let t0 = Date()
    var lastRaw: Int = -999
    var stable = 0
    var samples = 0
    var transitions: [(Double, Int, Int)] = []
    var paused = false
    while Date().timeIntervalSince(t0) < maxSeconds {
        let elapsed = Date().timeIntervalSince(t0)
        let tasks = (try? await client.listAllTasks()) ?? []
        guard let t = tasks.first(where: { $0.taskID == tid }) else {
            try? await Task.sleep(for: .milliseconds(intervalMs))
            continue
        }
        let raw = t.taskStatus.rawValue
        samples += 1
        if raw != lastRaw {
            transitions.append((elapsed, lastRaw, raw))
            print(String(format: "   [%@ +%6.3fs] %d → %d   progress=%d complete_time=%d save_path=\"%@\"",
                         fmt.string(from: Date()), elapsed, lastRaw, raw, t.progress.progress, t.completeTime, t.savePath))
            lastRaw = raw
            stable = 0
        } else {
            stable += 1
            // 稳定之后不再刷屏，只在等它满足「连续 N 次」时打点。
            if stable <= stableNeeded {
                print(String(format: "   [%@ +%6.3fs] %d（第 %d 次相同）  progress=%d complete_time=%d",
                             fmt.string(from: Date()), elapsed, raw, stable, t.progress.progress, t.completeTime))
            }
        }
        if stable >= stableNeeded && t.completeTime > 0 { break }
        if stable >= stableNeeded && raw == 0 { break }

        // 可选的「暂停探针」：在指定时刻发 TaskDo_PAUSE，看看任务自身的状态值
        // 会变成几。这是分辨「1 到底是 PAUSE 还是 ERROR」的唯一直接办法。
        if let pauseAt = env["JJD_TRACE_PAUSE_AT"].flatMap(Double.init),
           !paused, elapsed >= pauseAt, raw == 2 || raw == 3 {
            paused = true
            do {
                try await client.control(taskID: tid, do: .pause)
                print(String(format: "   [%@ +%6.3fs] ▶ 已发 TaskDo_PAUSE（此刻 raw=%d）",
                             fmt.string(from: Date()), elapsed, raw))
            } catch {
                print("   ⚠️ PAUSE 失败: \(error)")
            }
        }
        try? await Task.sleep(for: .milliseconds(intervalMs))
    }
    print("\n   采样次数=\(samples)  状态序列（原始值）：\(transitions.map { "\($0.1)→\($0.2)" }.joined(separator: "  "))")

    let dir = downloadDirectory()
    print("   ── 落盘目录 \(dir.path) ──")
    listRaw(dir)
}

func watch() async {
    h("任务列表（Ctrl-C 退出）")
    while true {
        if let tasks = try? await client.listAllTasks(), !tasks.isEmpty {
            for t in tasks {
                let p = t.progress
                print("  [\(t.taskStatus.label)] \(p.progress)%  \(p.downloadSpeed)  \(t.taskTitle.isEmpty ? t.taskID : t.taskTitle)")
            }
        } else {
            print("  （空）")
        }
        try? await Task.sleep(for: .seconds(4))
    }
}

// MARK: - 批量建任务（Task.NewBatch）实测

/// 命令行上的一条任务规格：`bvid,cid,清晰度,编码,接口,callback,音质`，后六项可省。
///
/// 为什么把 `callback` 也做成命令行参数：proto 里 `TaskCreationStatus` **只有**
/// `callback` 和 `err` 两个字段，没有任务 id。回调号是客户端唯一能自己塞进去、
/// 再指望核心原样吐回来的东西 —— 它能不能当「认领凭据」用，正是这次要看的事，
/// 所以必须能逐条指定、逐条对账。
struct BatchSpec {
    var bvid: String
    var cid: Int64 = 0
    var quality: UInt32 = 1000
    var codec: Jijidown_Core_VideoType = .hevc
    var api: DownloadAPI = .web
    var callback: UInt64 = 0
    /// 音质。默认 64K（最小的一档）。列表回复里有 `audio_badge` 字段，
    /// 所以换音质等于给它加了一个肉眼可分辨的标记 —— 多任务排序实测要靠它认人。
    var audio: UInt32 = AudioQuality.q64K.rawValue

    var brief: String {
        "接口=\(api.label) 清晰度=\(quality) 编码=\(codec.label) 音质=\(audio) callback=\(callback)"
    }

    static func parse(_ raw: String) -> BatchSpec? {
        let f = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let bv = f.first, !bv.isEmpty else { return nil }
        var s = BatchSpec(bvid: bv)
        func field(_ i: Int) -> String { i < f.count ? f[i] : "" }
        if let v = Int64(field(1)), !field(1).isEmpty { s.cid = v }
        if let v = UInt32(field(2)), !field(2).isEmpty { s.quality = v }
        // 空串保留默认值 —— 省得为了只改接口而在命令行上把编码也重打一遍。
        switch field(3).lowercased() {
        case "avc": s.codec = .avc
        case "av1": s.codec = .av1
        case "": break
        default: s.codec = .hevc
        }
        if let v = UInt32(field(4)), !field(4).isEmpty,
           let a = DownloadAPI(rawValue: v) { s.api = a }
        if let v = UInt64(field(5)), !field(5).isEmpty { s.callback = v }
        if let v = UInt32(field(6)), !field(6).isEmpty { s.audio = v }
        return s
    }

    /// 转成建任务参数。清晰度、音质都是**原样**的 id（`TaskParams` 的原样 init），
    /// 所以 1000 这种枚举里没有的档位不会被改成 1080P。
    func params() -> TaskParams {
        TaskParams(
            bvid: bvid,
            cid: cid,
            videoQuality: quality,
            audioQuality: audio,
            codec: codec,
            api: api,
            callback: callback
        )
    }
}

/// 快照任务列表，**原样保留核心给的顺序**。
///
/// 这次要回答的就是顺序，所以这里连一个 `sorted()` 都不能加 —— 任何本地排序
/// 都会把要看的证据抹掉。
func taskListSnapshot() async -> [Jijidown_Core_TaskStatusReply] {
    (try? await client.listAllTasks()) ?? []
}

/// 按核心给的先后打印列表。`mark` 里的 id 会被标出来，方便一眼看出
/// 「哪几个是这次建的」以及它们落在第几位。
func printTaskList(_ ts: [Jijidown_Core_TaskStatusReply], mark: Set<String> = []) {
    if ts.isEmpty {
        print("      （列表为空）")
        return
    }
    for (i, t) in ts.enumerated() {
        let tag = mark.contains(t.taskID) ? "   ← 本次新建" : ""
        print("      [\(i)] \(t.taskID)")
        print("           状态=\(t.displayLabel) 接口=\(t.apiType.label) 清晰度角标=\"\(t.videoBadge)\" 音质角标=\"\(t.audioBadge)\" 进度=\(t.progress.progress)%\(tag)")
        // add_time 是核心排序用的键（二进制里有 core/task.sortTaskByAddTime），
        // 所以必须打出来 —— 同一秒建的任务会不会因此并列，就看这几个数字。
        print("           add_time=\(t.addTime)  complete_time=\(t.completeTime)  标题=\"\(t.taskTitle)\"")
    }
}

/// 「批量」实测主流程。
///
/// 已知结论：**`NewBatch` 被授权门挡死**（实测 `failedPrecondition:
/// DownloadBatch function not allowed`），所以批量下载的正路是**逐条 `Task.New`**
/// —— 这个子命令留着，是为了随时能再复验那道门。
///
/// 一次把三件事的证据都摆出来：
///   1. `NewBatch` 通不通（不通就把归类后的错误记下）；
///   2. 回复里每条 `TaskCreationStatus` 的 callback / err，条数对不对得上；
///   3. 提交后 `Task.List` 里的顺序，与提交顺序是否一致。
///
/// 环境变量：
///   `JJD_BATCH_SINGLE=1`   逐条走 `Task.New` 提交（对照组；默认走 NewBatch）
///   `JJD_BATCH_SETTLE=秒`  提交后等多久再读列表（默认 6）
///   `JJD_BATCH_CLEANUP=1`  结束后把这些任务删掉并核对列表回到基线
func runBatch(specs: [BatchSpec], single: Bool) async {
    let settle = env["JJD_BATCH_SETTLE"].flatMap(Int.init) ?? 6
    let cleanup = env["JJD_BATCH_CLEANUP"] == "1"

    // 先记下账号面：这道门到底跟登录态/授权分级有没有关系，得有个凭据。
    // 前一轮实测已知 GetVideoList / DownloadVideo 是通的（登录换来的 access_token
    // 解开的），所以这里能 INFO 通就说明「登录态 + 基础授权」是有的。
    print("\n── 账号与授权面")
    if let u = try? await client.userInfo() {
        print("   User.Info: uname=\"\(u.uname)\"  mid=\(u.mid)  is_login=\(u.isLogin)  VIP=\(u.vipStatus)  vip_label=\"\(u.vipLabelText)\"  badge=\"\(u.badge)\"")
    } else {
        print("   User.Info 取不到")
    }
    if let i = try? await client.videoInfo(specs[0].bvid) {
        print("   Bvideo.Info（授权门试金石，通=GetVideoList 已放行）：\"\(i.displayTitle)\"")
    } else {
        print("   Bvideo.Info 被挡（GetVideoList 没放行）")
    }

    let baseline = await taskListSnapshot()
    let before = Set(baseline.map(\.taskID))
    print("\n── 提交前基线（\(before.count) 个）")
    printTaskList(baseline)

    print("\n── 待提交 \(specs.count) 条（这个先后就是「提交顺序」）")
    for (i, s) in specs.enumerated() {
        print("   [\(i)] \(s.bvid) cid=\(s.cid) \(s.brief)")
    }

    if single {
        print("\n── 提交方式：逐条 Task.New（对照组，不走 NewBatch）")
        // 条与条之间留个间隔。
        //
        // 为什么要这个开关：核心排序用的键只到「秒」，留 0 秒时几条任务会并列，
        // 于是「并列名次的先后」和「提交先后」就分不开了。留上几秒，让 add_time
        // 明确拉开，才能验证「顺序 = 按 add_time 排」这个说法本身成不成立。
        let gap = env["JJD_BATCH_GAP"].flatMap(Double.init) ?? 0
        for (i, s) in specs.enumerated() {
            if i > 0, gap > 0 { try? await Task.sleep(for: .seconds(gap)) }
            do {
                try await client.newTask(s.params())
                print("   [\(i)] New 返回成功（Empty，没有任何内容）：\(dumpParams(s.params()))")
            } catch {
                print("   [\(i)] New ❌ \(error)")
            }
        }
    } else {
        print("\n── 提交方式：一次 Task.NewBatch（\(specs.count) 条）")
        for (i, s) in specs.enumerated() {
            print("   [\(i)] \(dumpParams(s.params()))")
        }
        do {
            let reply = try await client.newTasks(specs.map { $0.params() })
            // textFormat 是逐字段的原文，比我们自己 print 更接近「一字不差」。
            print("\n── Task.NewBatch 原始回复（textFormat 逐字）")
            let text = reply.textFormatString()
            if text.isEmpty {
                print("   ＜空回复：一个字段都没有＞")
            } else {
                for line in text.split(whereSeparator: \.isNewline) { print("   \(line)") }
            }
            print("\n── 逐条拆开 TaskCreationStatus（条数=\(reply.taskCreationStatus.count)）")
            if reply.taskCreationStatus.isEmpty {
                print("   ＜数组为空＞")
            }
            for (i, st) in reply.taskCreationStatus.enumerated() {
                print("   [\(i)] callback=\(st.callback)  err=\"\(st.err)\"")
            }
            print("   条数对比：请求 \(specs.count) 条 → 回复 \(reply.taskCreationStatus.count) 条")
        } catch {
            print("\n── Task.NewBatch ❌ \(error)")
            // 这道门与登录前的 `DownloadVideo function not allowed` 同形，
            // 所以应当落在 `.needsAuthorization`：界面文案是「回账号页看看」，
            // 而不是「核心明确表示不做这个」。
            // （以前这里还会再发一次**不归类**的请求拿 gRPC 状态码 —— 那几个
            //   实测钩子已经从库里删掉了，现在只剩 CoreError 这一种说法。）
            print("   （这句原文就是核心的原话；归类只丢掉 gRPC 状态码，message 不动）")
        }
    }

    print("\n── 等 \(settle) 秒，让任务进列表")
    try? await Task.sleep(for: .seconds(settle))

    let after = await taskListSnapshot()
    let newIDs = after.map(\.taskID).filter { !before.contains($0) }
    print("\n── 提交后 Task.List（status=TaskStatusType 0）的顺序")
    printTaskList(after, mark: Set(newIDs))
    print("\n── 本次新建的 id（按它们在列表里的先后排）")
    for (i, id) in newIDs.enumerated() { print("   [\(i)] \(id)") }

    // 反复读同一份列表。
    //
    // 为什么要扫这么多遍：核心是 `sortTaskByAddTime` 排序，而这个键只到「秒」。
    // 同一秒里建的几个任务因此是并列的，并列名次的先后完全取决于排序算法
    // 拿到的输入序列 —— 输入如果来自 Go 的 map 遍历，那每一遍都可能不一样。
    // 客户端「按列表顺序配标题」的做法能不能站住，就看这几遍一不一样。
    if let sweeps = env["JJD_BATCH_SWEEPS"].flatMap(Int.init), sweeps > 0 {
        print("\n── 连读 \(sweeps) 遍，看顺序稳不稳（只列 id 顺序）")
        var seen: [[String]] = []
        for n in 1...sweeps {
            let snap = await taskListSnapshot().filter { !before.contains($0.taskID) }
            let now = snap.map(\.taskID)
            seen.append(now)
            // 连状态一起打：这样「顺序变了」就排除掉「是不是状态变了才挪位」这个解释。
            let short = snap
                .map { "\($0.taskID.prefix(8))(\($0.displayLabel))" }
                .joined(separator: " ")
            print("   第 \(n) 遍：\(short.isEmpty ? "（空）" : short)")
            if n < sweeps { try? await Task.sleep(for: .seconds(1)) }
        }
        let distinct = Set(seen.map { $0.joined(separator: ",") })
        print("   不同顺序的种数 = \(distinct.count) → \(distinct.count == 1 ? "✅ 稳定" : "❌ 不稳定")")
    }

    guard cleanup else {
        print("\n（按 JJD_BATCH_CLEANUP 未设置，保留任务不删）")
        return
    }
    print("\n── 清理：逐个 Task.Control(DELETE_AND_FILE)")
    for id in newIDs {
        do {
            try await client.control(taskID: id, do: .deleteAndFile)
            print("   ✅ 已删 \(id)")
        } catch {
            print("   ❌ 删 \(id) 失败：\(error)")
        }
    }
    for _ in 0..<10 {
        try? await Task.sleep(for: .seconds(1))
        if Set((await taskListSnapshot()).map(\.taskID)) == before { break }
    }
    let final = await taskListSnapshot()
    print("── 清理后的列表")
    printTaskList(final)
    print("   与基线一致：\(Set(final.map(\.taskID)) == before ? "✅ 是" : "❌ 否")")
}

// MARK: - TV / APP 接口实测

/// 打印核心抛回来的错误：归类后的说法 + 它的 debugDescription。
///
/// 以前这里还会再打一份「**未归类**的原文」拿 gRPC 状态码 —— 那要靠库里几个
/// 不做归类的实测钩子，而那些钩子已经删掉了（它们绕过 `CoreError` 归类，
/// 不该留在库里）。现在只剩 `CoreError` 这一种说法，它的 message 仍是核心原话，
/// 丢掉的只有状态码。
func dumpError(_ tag: String, _ error: any Error) {
    print("   \(tag)：\(error)")
    print("   \(tag) debugDescription：\(String(reflecting: error))")
}

/// 单个任务的原样快照，一行。
func briefTask(_ t: Jijidown_Core_TaskStatusReply) -> String {
    let p = t.progress
    return "状态=\(t.displayLabel) 接口=\(t.apiType.label) 角标=\"\(t.videoBadge)\"/\"\(t.audioBadge)\" 编码=\(t.videoCodec) 进度=\(p.progress)% \(p.completedLength)/\(p.totalLength) 速度=\(p.downloadSpeed) 落盘=\"\(t.savePath)\""
}

/// TV / APP 接口实测主流程。
///
/// 已知结论（r339）：任务**建得起来**，3~4 秒后在取播放地址那一步失败
/// （核心日志 `API TV not allowed` / `API APP not allowed`），零字节，
/// 任务转错误。而且**核心不把错误文本回给客户端**（`TaskStatusReply` 没有错误
/// 字段），所以「为什么失败」只能靠核心日志，界面能做的只有按 `api_type` 事后归因。
/// 这个子命令留着是为了随时能再复验。
///
/// 输出分三段，要回答：
///   1. 建任务这一步就被拒，还是核心照收、到取播放地址时才失败？
///   2. 任务有没有真进列表、有没有真下出字节？**真下就立刻删任务** ——
///      实测的目的不是把片子下下来，别在临时目录里堆大文件。
///   3. 该任务的最终全字段快照（状态、落盘路径）。
func runAPIProbe(
    bv: String, cid: Int64,
    api: DownloadAPI,
    quality: UInt32, codec: Jijidown_Core_VideoType
) async {
    let watch = env["JJD_API_WATCH"].flatMap(Double.init) ?? 25

    print("\n── 账号与授权面（用来判断这道门跟登录/授权有没有关系）")
    if let u = try? await client.userInfo() {
        print("   User.Info: uname=\"\(u.uname)\"  mid=\(u.mid)  is_login=\(u.isLogin)  VIP=\(u.vipStatus)  vip_label=\"\(u.vipLabelText)\"  badge=\"\(u.badge)\"")
    } else {
        print("   User.Info 取不到")
    }
    if let i = try? await client.videoInfo(bv) {
        print("   Bvideo.Info（WEB 授权门试金石，通=GetVideoList 已放行）：\"\(i.displayTitle)\"")
    } else {
        print("   Bvideo.Info 被挡 → WEB 这条链本身就不通，下面 TV/APP 的结论要打折扣")
    }

    let baseline = await taskListSnapshot()
    let before = Set(baseline.map(\.taskID))
    print("\n── 提交前基线（\(before.count) 个任务）")
    printTaskList(baseline)

    let params = TaskParams(
        bvid: bv, cid: cid,
        videoQuality: quality,
        audioQuality: AudioQuality.q192K.rawValue,
        codec: codec,
        api: api
    )
    print("\n── 建任务（api_type=\(api.rawValue) \(api.label)，清晰度 \(quality)，编码 \(codec.label)）")
    print("   Task.New 请求逐字段：\(dumpParams(params))")

    do {
        try await client.newTask(params)
        print("   ✅ Task.New 被核心**照收**（没有在 gRPC 层被拒）→ 失败只可能发生在后续阶段")
    } catch {
        dumpError("Task.New ❌", error)
    }

    print("\n── 盯 \(Int(watch)) 秒，看列表里有没有它、有没有真下字节")
    let dl = downloadDirectory()
    var mine: String?
    var lastLine = ""
    var deleted = false
    let deadline = Date().addingTimeInterval(watch)
    while Date() < deadline {
        // 半秒一轮：TV/APP 要是真能用，从「开始下」到「删掉」之间不该留太宽的口子。
        try? await Task.sleep(for: .milliseconds(500))
        let now = (try? await client.listAllTasks()) ?? []
        guard let t = now.first(where: { !before.contains($0.taskID) }) else { continue }
        mine = t.taskID
        let p = t.progress
        let line = briefTask(t)
        if line != lastLine {
            print("   \(line)")
            lastLine = line
        }
        // 判据是**真的下了字节**，不是「状态=下载中」。
        //
        // 踩过的坑：TV 任务一建出来状态就是 TASK_RUNNING，但那时它还在取
        // 播放地址，几秒后才会因为 `API TV not allowed` 翻成 TASK_ERROR。
        // 一见 RUNNING 就删，等于把要观测的那一步掐掉了 —— 第一次跑就是这么
        // 误判成「TV 能用」的。所以只认字节和落盘文件这两个硬信号。
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dl.path))?.count ?? 0
        if p.progress > 0 || !p.completedLength.isEmpty || files > 0 {
            print("   ⚠️ 真下出字节了（进度 \(p.progress)% / \(p.completedLength)，落盘 \(files) 个文件）→ 立刻 Task.Control(DELETE_AND_FILE)")
            do {
                try await client.control(taskID: t.taskID, do: .deleteAndFile)
                print("   ✅ 已删 \(t.taskID)")
                deleted = true
            } catch {
                print("   ❌ 删除失败：\(error)")
            }
            break
        }
    }
    if mine != nil, !deleted {
        print("   （\(Int(watch)) 秒内一个字节都没下 —— 这不是「能用」，见下面的最终状态与核心日志）")
    }

    if let id = mine {
        print("\n── 该任务的全字段快照")
        if let t = try? await client.taskStatus(taskID: id) { dumpTask(t) } else { print("   Task.Status 取不到") }
        if !deleted {
            print("\n── 收尾：删掉这个任务（不留痕）")
            do {
                try await client.control(taskID: id, do: .deleteAndFile)
                print("   ✅ 已删 \(id)")
            } catch {
                print("   ❌ 删除失败：\(error)")
            }
        }
    } else {
        print("\n── 列表里**始终没有**新任务出现（建任务那一步就没成，或核心没把它登记进列表）")
    }

    print("\n── 收尾后的列表")
    printTaskList(await taskListSnapshot())
}

// MARK: - Status.CheckUpdate 实测

/// 调 `Status.CheckUpdate` 这条服务端流，把每条回复的每个字段原样打出来。
///
/// `change_log` 按约定截断到 500 字：它可能是整篇更新日志，原样灌进终端
/// 会把别的证据挤没。
func runCheckUpdate() async {
    let limit = env["JJD_CU_LIMIT"].flatMap(Int.init) ?? 10
    let timeout = env["JJD_CU_TIMEOUT"].flatMap(Double.init) ?? 30
    // 反复调几次：核心在启动时已经 `[update] check update` 过一次，所以
    // 「每次调是重新去服务器查，还是把启动那次的结果回放给我们」这件事，
    // 只能靠多次调用来分辨（回放的话每次内容完全一样）。
    let calls = env["JJD_CU_CALLS"].flatMap(Int.init) ?? 1
    let gap = env["JJD_CU_GAP"].flatMap(Double.init) ?? 3

    for call in 1...calls {
        if call > 1 {
            print("\n── 等 \(Int(gap)) 秒后第 \(call) 次调用")
            try? await Task.sleep(for: .seconds(gap))
        }
        await oneCheckUpdate(limit: limit, timeout: timeout)
    }
}

private func oneCheckUpdate(limit: Int, timeout: Double) async {
    print("\n── Status.CheckUpdate（服务端流，最多收 \(limit) 条 / 最多等 \(Int(timeout)) 秒）")
    print("   请求体 = google.protobuf.Empty（proto 里没有参数）")

    let deadline = Date().addingTimeInterval(timeout)
    var n = 0
    // 库里的流自带 20 秒兜底超时（核心关不关流是它的自由，见 CoreClient.checkUpdate）。
    // 这里给它放宽 10 秒，让探针自己的 deadline 先生效 —— 探针要观察的正是
    // 「核心到底会不会自己把流关掉」，被库的超时先截断就看不出来了。
    do {
        for try await reply in client.checkUpdate(timeout: .seconds(timeout + 10)) {
            n += 1
            print("\n   ── 第 \(n) 条 StatusCheckUpdateReply")
            print("      status    = \(reply.status.rawValue) (\(reply.status.label))")
            let log = reply.changeLog
            print("      change_log 长度 = \(log.count) 字")
            if log.isEmpty {
                print("      change_log = ＜空串＞")
            } else {
                let shown = log.count > 500 ? String(log.prefix(500)) + "……（截断，原文 \(log.count) 字）" : log
                for line in shown.split(whereSeparator: \.isNewline) { print("      | \(line)") }
            }
            print("      原始 textFormat：\(reply.textFormatString().replacingOccurrences(of: "\n", with: " ⏎ "))")
            if n >= limit { print("\n   （到上限 \(limit) 条，主动断开）"); break }
            if Date() > deadline { print("\n   （到时间上限 \(Int(timeout)) 秒，主动断开）"); break }
        }
        print("\n   ✅ 流正常结束（共 \(n) 条）")
    } catch {
        print("\n   ❌ 流中断（已收到 \(n) 条）")
        dumpError("CheckUpdate ❌", error)
    }
}

// MARK: - 分发

switch args.first {
case "dl":
    // 用法: dl <BV> [save_filename] [清晰度id] [编码 avc|hevc|av1]
    //
    // 第 2 个位置参数是 `TaskNewReq.save_filename`（命名模板的**主干名**）。
    // 它**确实生效**：核心产出 `<它> (清晰度角标, 编码, 音质角标, 接口).<扩展名>`。
    // 扩展名由核心决定（视频永远 .mp4，仅音频 .mp3），带进去只会得到双扩展名；
    // 里面的 `/` 会让 ffmpeg 失败、任务转错误，所以别拿它试路径。
    guard args.count >= 2 else {
        print("用法: JiJiProbe dl <BV号> [save_filename] [清晰度id=80] [编码=hevc]")
        print("  清晰度 id: 126=杜比视界 120=4K 80=1080P 64=720P 32=480P 16=360P")
        print("  不在表里的清晰度 id 会**原样**发给核心，不会被改写成 1080P，并打印实际发出的值")
        print("  环境变量：JJD_HOST / JJD_PORT / JJD_DOWNLOAD_DIR")
        print("           JJD_AUDIO_Q=30216（音质 id，默认 30280）")
        print("           JJD_AUDIO_ONLY=1（仅下载音频，产物是 mp3）")
        print("           JJD_SAVE_FILENAME=名字（save_filename，覆盖第 2 个位置参数）")
        print("           JJD_RAW_QUALITY=1000（覆盖位置参数里的清晰度 id）")
        print("           JJD_CALLBACK=111（TaskNewReq.callback，默认 0）")
        print("           JJD_NO_ADOPT=1（不改名，留核心原始文件名）")
        exit(2)
    }
    // 清晰度 id **原样透传**，不再兜底成 1080P。
    //
    // 以前这里写的是 `VideoQuality(rawValue: qid) ?? .p1080`，于是 `dl <BV> "" 1000`
    // 会静默变成「又跑了一遍 1080P」——上一轮实测正是因此得出了错误结论。
    // 探针本来就是拿来试任意值的，兜底等于把实验条件悄悄改掉。
    // 现在参数一路都是 `UInt32`，认不出的 id 也会原样发出去，并且打印实际值
    // （见 `dumpParams`）。
    let qid = env["JJD_RAW_QUALITY"].flatMap(UInt32.init)
        ?? (args.count >= 4 ? UInt32(args[3]) ?? 80 : 80)
    let codecName = args.count >= 5 ? args[4].lowercased() : "hevc"
    let codec: Jijidown_Core_VideoType =
        codecName == "avc" ? .avc : codecName == "av1" ? .av1 : .hevc
    // 音质 / 仅下载音频 / save_filename 走环境变量与既有的位置参数，
    // 不动位置参数的顺序：老命令行长什么样现在还长什么样。
    let audio = env["JJD_AUDIO_Q"].flatMap(UInt32.init).flatMap(AudioQuality.init(rawValue:))
        ?? .q192K
    await download(
        bv: args[1],
        filename: env["JJD_SAVE_FILENAME"] ?? (args.count >= 3 ? args[2] : ""),
        quality: qid,
        audio: audio,
        codec: codec,
        audioOnly: env["JJD_AUDIO_ONLY"] == "1",
        noAdopt: env["JJD_NO_ADOPT"] == "1",
        callback: env["JJD_CALLBACK"].flatMap(UInt64.init) ?? 0
    )
    exit(0)

case "trace":
    // 用法: trace <BV> [清晰度id] [编码] [接口 0/1/2]
    // 目的：高频读同一条任务的 task_status **原始整数值**。
    //
    // 为什么不打印本地枚举标签：仓库里的 TaskStatusType 与核心实际枚举可能整体
    // 错位，用错位的名字去描述观测值只会把结论带偏。这里只出 rawValue，名字由
    // 观测之后另行对账。
    guard args.count >= 2 else {
        print("用法: JiJiProbe trace <BV号> [清晰度id=80] [编码=hevc] [接口=0]")
        print("  环境变量：JJD_HOST / JJD_PORT / JJD_DOWNLOAD_DIR")
        print("           JJD_TRACE_MS=300（采样间隔毫秒）")
        print("           JJD_TRACE_MAX=180（最长追踪秒数）")
        print("           JJD_TRACE_STABLE=5（连续多少次不变算「稳定」）")
        print("           JJD_RAW_QUALITY=1000（原样送清晰度，覆盖位置参数）")
        exit(2)
    }
    let tq = env["JJD_RAW_QUALITY"].flatMap(UInt32.init)
        ?? (args.count >= 3 ? UInt32(args[2]) : 80) ?? 80
    let tcName = args.count >= 4 ? args[3].lowercased() : "hevc"
    let tc: Jijidown_Core_VideoType =
        tcName == "avc" ? .avc : tcName == "av1" ? .av1 : .hevc
    // 接口号照旧是 0/1/2，只是换成用 `DownloadAPI` 收 —— 提交时要的是它。
    let tApi = (args.count >= 5 ? UInt32(args[4]) : 0).flatMap(DownloadAPI.init(rawValue:)) ?? .web
    await trace(bv: args[1], rawQuality: tq, codec: tc, api: tApi)
    exit(0)

case "batch":
    // 用法: batch <规格> [<规格> ...]   规格 = bvid,cid,清晰度,编码,接口,callback
    guard args.count >= 2 else {
        print("用法: JiJiProbe batch <规格> [<规格> ...]")
        print("  规格 = bvid,cid,清晰度,编码,接口,callback,音质（后六项可省）")
        print("    清晰度默认 1000（原样发出，不会被改写成 1080P）")
        print("    编码 avc|hevc|av1；接口 0=WEB 1=TV 2=APP")
        print("    callback 是任意 UInt64；音质默认 30216(64K)")
        print("  ⚠️ 默认走 NewBatch，而它**目前被授权门挡死**（DownloadBatch function")
        print("     not allowed）。要真建任务请加 JJD_BATCH_SINGLE=1（逐条 Task.New）。")
        print("  环境变量：JJD_HOST / JJD_PORT / JJD_DOWNLOAD_DIR")
        print("           JJD_BATCH_SINGLE=1（改用逐条 Task.New 对照）")
        print("           JJD_BATCH_GAP=秒（单条模式里两条之间隔多久，默认 0）")
        print("           JJD_BATCH_SETTLE=秒（默认 6）")
        print("           JJD_BATCH_SWEEPS=N（再连读 N 遍列表，看顺序稳不稳）")
        print("           JJD_BATCH_CLEANUP=1（跑完删掉这些任务并核对回基线）")
        exit(2)
    }
    let specs = args.dropFirst().compactMap(BatchSpec.parse)
    guard !specs.isEmpty else { print("没有解析出任何规格"); exit(2) }
    await runBatch(specs: specs, single: env["JJD_BATCH_SINGLE"] == "1")
    exit(0)

case "cid":
    // 用法: cid <BV号> [<BV号> ...]  —— 打印每个视频的分P cid，供 batch 用
    guard args.count >= 2 else { print("用法: JiJiProbe cid <BV号> [<BV号> ...]"); exit(2) }
    for bv in args.dropFirst() {
        do {
            let info = try await client.videoInfo(bv)
            let pages = info.block.flatMap(\.list)
            print("── \(bv)  标题=\"\(info.displayTitle)\"  UP=\(info.upName)  分P=\(pages.count)")
            for p in pages.prefix(12) {
                print("     index=\(p.pageIndex) cid=\(p.pageCid) aid=\(p.pageAv) 标题=\"\(p.pageTitle)\"")
            }
        } catch {
            print("── \(bv)  ❌ \(error)")
        }
    }
    exit(0)

case "api":
    // 用法: api <BV号> <cid> <接口 0=WEB|1=TV|2=APP> [清晰度=80] [编码=hevc]
    guard args.count >= 4 else {
        print("用法: JiJiProbe api <BV号> <cid> <接口 0=WEB|1=TV|2=APP> [清晰度=80] [编码=hevc]")
        print("  环境变量：JJD_HOST / JJD_PORT / JJD_API_WATCH=秒（盯多久，默认 15）")
        exit(2)
    }
    guard let cid = Int64(args[2]), let rawAPI = UInt32(args[3]),
          let api = DownloadAPI(rawValue: rawAPI)
    else { print("cid 或接口号解析不了；接口只能是 0/1/2"); exit(2) }
    let q = args.count >= 5 ? UInt32(args[4]) ?? 80 : 80
    let codecName = args.count >= 6 ? args[5].lowercased() : "hevc"
    let codec: Jijidown_Core_VideoType =
        codecName == "avc" ? .avc : codecName == "av1" ? .av1 : .hevc
    await runAPIProbe(bv: args[1], cid: cid, api: api, quality: q, codec: codec)
    exit(0)

case "checkupdate":
    await runCheckUpdate()
    exit(0)

case "watch":
    await watch()

case "status":
    h("User.Info")
    do {
        let u = try await client.userInfo()
        print("   ✅ \(u.uname)  mid=\(u.mid)  VIP=\(u.vipStatus)")
    } catch {
        print("   ⚠️  \(error)")
    }

default:
    do {
        h("Status.Ping")
        let pong = try await client.ping()
        print("   ✅ \(pong.serverName)")
        print("      \(pong.osSystemName)   icon=\(pong.osIcon.rawValue)")
    } catch {
        print("   ❌ \(error)")
    }

    do {
        h("User.Info")
        let u = try await client.userInfo()
        print("   ✅ \(u.uname)  mid=\(u.mid)  VIP=\(u.vipStatus)  \(u.vipLabelText)")
    } catch {
        print("   ⚠️  \(error)")
    }

    do {
        h("Bvideo.CheckContent  BV1t93W6CEh2")
        let r = try await client.checkContent("BV1t93W6CEh2")
        print("   ✅ valid=\(r.isValid)  id=\(r.blinkResult.id)")
    } catch {
        print("   ❌ \(error)")
    }

    do {
        h("Bvideo.Info  BV1t93W6CEh2   ← 授权门的试金石")
        let i = try await client.videoInfo("BV1t93W6CEh2")
        print("   ✅ \(i.displayTitle)")
    } catch {
        print("   ⚠️  \(error)")
    }
}
