import Foundation
import JiJiKit
import JiJiProtos

// 命令行验证工具。子命令：
//   （无参数）        连通性与权限探针
//   status           登录状态
//   dl <BV号> [文件名] 走完整下载流程并轮询到结束
//   watch            实时盯任务列表

let args = Array(CommandLine.arguments.dropFirst())
let client = try CoreClient()
await client.start()
defer { Task { await client.shutdown() } }

func h(_ t: String) { print("\n── \(t)") }

// MARK: - 下载并轮询到结束

/// 从 config.yaml 里读下载目录，读不到就用默认值。
///
/// 直接照着行首找 `download-dir:` —— 没必要为一行配置引入 YAML 解析。
func downloadDirectory() -> URL {
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

func download(
    bv: String,
    filename: String,
    quality: VideoQuality = .p1080,
    audio: AudioQuality = .q192K,
    codec: Jijidown_Core_VideoType = .hevc
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
    let before = Set((try? await client.listTasks(status: .taskError))?.map(\.taskID) ?? [])
    do {
        try await client.newTask(
            aid: aid, bvid: bv, cid: cid,
            quality: quality,
            audio: audio,
            codec: codec,
            api: .web,
            // 核心无视这个参数，实测传了也没用 —— 文件名靠完成后改名补。
            saveFilename: filename
        )
        print("   ✅ 已提交，aid=\(aid) cid=\(cid) 清晰度=\(quality.label) 编码=\(codec)")
    } catch {
        print("   ❌ \(error)")
        return
    }

    var mine: Jijidown_Core_TaskStatusReply?
    for _ in 0..<40 {
        try? await Task.sleep(for: .seconds(1))
        let now = (try? await client.listTasks(status: .taskError)) ?? []
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
    let coreName = task.coreOutputName
    print("   任务 id=\(taskID.prefix(12))…  核心产物名=\(coreName)")

    h("轮询进度（最多 30 分钟）")
    let deadline = Date().addingTimeInterval(1800)
    var lastLine = ""
    while Date() < deadline {
        try? await Task.sleep(for: .seconds(3))
        guard let tasks = try? await client.listTasks(status: .taskError),
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
        // 核心在合并阶段才落盘，这时文件才存在。
        let dir = downloadDirectory()
        if let url = OutputNaming.adopt(in: dir, coreName: coreName, title: title) {
            print("      文件: \(url.path)")
        } else {
            print("      ⚠️  改名失败，产物可能还叫 \(coreName)（在 \(dir.path)）")
        }
        return
    }
    print("   ⏱ 超时")
}

func watch() async {
    h("任务列表（Ctrl-C 退出）")
    while true {
        if let tasks = try? await client.listTasks(status: .taskError), !tasks.isEmpty {
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

// MARK: - 分发

switch args.first {
case "dl":
    // 用法: dl <BV> [文件名] [清晰度id] [编码 avc|hevc|av1]
    guard args.count >= 2 else {
        print("用法: JiJiProbe dl <BV号> [文件名] [清晰度id=80] [编码=hevc]")
        print("  清晰度 id: 126=杜比视界 120=4K 80=1080P 64=720P 32=480P 16=360P")
        exit(2)
    }
    let qid = args.count >= 4 ? UInt32(args[3]) ?? 80 : 80
    let quality = VideoQuality(rawValue: qid) ?? .p1080
    let codecName = args.count >= 5 ? args[4].lowercased() : "hevc"
    let codec: Jijidown_Core_VideoType =
        codecName == "avc" ? .avc : codecName == "av1" ? .av1 : .hevc
    await download(
        bv: args[1],
        filename: args.count >= 3 ? args[2] : "",
        quality: quality,
        codec: codec
    )
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
