import Foundation

/// 核心产物的命名与改名。
///
/// ## 为什么需要这一层
///
/// 唧唧核心（r339）**不会给下载产物起一个像样的名字**，实测结论有三条：
///
/// 1. 命名模板是 `%s (%s, %s, %s, %s)` —— 第一个 `%s` 是标题，后面依次是
///    清晰度角标、编码、音质角标、接口。核心**不填标题**，于是文件名永远以
///    一个空格开头，例如 ` (高清 1080P, HEVC, 极高音质, WEB).mp4`。
/// 2. `TaskNewReq.save_filename` **传了完全没用**。实测传 `"墨脱-1080P"`，
///    产出照样是上面那个名字。
/// 3. 因此文件名**只由四个角标决定**，两个同档位任务会写到同一个路径上，
///    后完成的把先完成的直接覆盖掉 —— 这就是「下完一个另一个不见了」的原因。
///
/// 客户端能做的：任务完成后按标题改名，并且**绝不覆盖已有文件**。
/// 并行下载的坑则在配置层面用 `max-task: 1` 堵住（见 `CoreManager.writeConfig`）。
///
/// 单独成类型而不是挂在 `CoreManager` 上，是因为命令行探针也要用这套逻辑，
/// 而探针不需要为了改个名去拉起一个 `CoreManager`。
public enum OutputNaming {

    /// 核心会把这个任务写成什么文件名。
    ///
    /// 角标直接取自任务回复里的字段，不自己复刻核心「清晰度 id → 中文角标」
    /// 的映射表 —— 那表我们并不掌握，猜错就配不上号了。
    public static func coreName(
        videoBadge: String,
        codec: String,
        audioBadge: String,
        api: String,
        ext: String = "mp4"
    ) -> String {
        " (\(videoBadge), \(codec), \(audioBadge), \(api)).\(ext)"
    }

    /// 核心的文件名 → 我们想要的最终文件名。
    ///
    /// 只在前面加标题，核心那串角标原样留着：用户一眼能看出档位，
    /// 也避免我们自己重新拼角标拼错。
    public static func finalName(forCoreName coreName: String, title: String) -> String {
        let clean = sanitized(title)
        return clean.isEmpty ? coreName : clean + coreName
    }

    /// 标题会直接进文件名，得挡掉路径分隔符和会让文件变隐藏的前导点。
    ///
    /// 核心自己也做了一层过滤（`bilibili.formatFileName`），但我们是在核心之外
    /// 改名的，这一层不能省 —— 标题里一个 `/` 就会让 `moveItem` 直接失败。
    public static func sanitized(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\u{0}"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.drop(while: { $0 == "." }).prefix(120))
    }

    /// 把核心产出的那个「没名字」的文件按标题改名，返回最终路径。
    ///
    /// 必须在任务**完成后**调用：核心是在合并阶段才把文件落盘的
    /// （日志里的 `Output file location:`），在那之前磁盘上没有这个文件。
    ///
    /// 目标名已存在时自动加 `(2)`、`(3)` 序号 —— **绝不覆盖**。
    /// 核心自己完全没有这道保护，客户端得补上。
    @discardableResult
    public static func adopt(in directory: URL, coreName: String, title: String) -> URL? {
        let fm = FileManager.default
        let source = directory.appendingPathComponent(coreName)
        guard fm.fileExists(atPath: source.path) else { return nil }

        var target = directory.appendingPathComponent(
            finalName(forCoreName: coreName, title: title)
        )
        let ext = target.pathExtension
        let stem = target.deletingPathExtension().lastPathComponent

        var n = 2
        while fm.fileExists(atPath: target.path) {
            guard n <= 999 else { return nil }
            target = directory.appendingPathComponent("\(stem) (\(n)).\(ext)")
            n += 1
        }

        do {
            try fm.moveItem(at: source, to: target)
            return target
        } catch {
            return nil
        }
    }
}
