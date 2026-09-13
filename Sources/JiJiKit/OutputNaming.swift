import Foundation

/// 核心产物的命名、定位与撞名避让。
///
/// ## 核心到底把文件叫什么
///
/// 唧唧核心（r339）的命名模板是 `%s (%s, %s, %s, %s).<扩展名>`：
///
///     主干名 (清晰度角标, 编码, 音质角标, 接口).mp4
///
/// 主干名就是 `TaskNewReq.save_filename`（字段 9）。三条实测：
///
/// 1. **传了就生效**，它原样落在主干位上。传空串时主干位为空，文件名以一个
///    空格开头（` (高清 1080P, HEVC, 极高音质, WEB).mp4`）。
/// 2. **扩展名由核心决定**，视频永远 `.mp4`、仅音频永远 `.mp3`；带进去的扩展名
///    不会被去掉（`标题.mp4` → `标题.mp4 (…).mp4`，双扩展名）。所以主干名里
///    不该带扩展名。
/// 3. **主干名里带 `/` 会让 ffmpeg 失败、任务转 TASK_ERROR 且不产出文件** ——
///    提交前必须过一遍 `sanitized`。
///
/// ## 为什么客户端不再「改名」
///
/// 早先的做法是：主干留空 → 任务完成后按角标复刻核心的文件名 → 找到它再改名
/// 成「标题 + 角标」。这条路有两个硬伤：
///
/// - **复刻角标是猜的。** 实测任务回复里的角标和文件名里的角标会不一致
///   （列表里是 `unknown (1000)/HEVC`，文件却叫 `unknown (0)/UNKNOWN`），
///   复刻出来的名字迟早对不上，然后就什么也找不着了。
/// - 改名本身只是把「文件名里已经有标题」这件事又做了一遍。
///
/// 现在主干名就是标题，核心产出即成品，客户端只做两件事：**提交前**避让撞名、
/// **完成后**按主干前缀去目录里认领产物（`locate`）。
///
/// ## 「绝不覆盖」的保证现在落在提交这一侧
///
/// 核心遇到同名文件是**静默覆盖**的（不加 `(2)`、不报错），这个行为没变。
/// 既然不再改名，就不能再靠改名时加序号来兜底，于是防线前移到提交前：
/// `availableStem` 会拿「目录里已有的文件名 + 本次运行已占用的主干」一起比，
/// 撞了就依次加 ` (2)`、` (3)`。详细判据见 `matches` —— **撞名是分扩展名的**：
/// 视频 `.mp4` 与仅音频 `.mp3` 即使主干同名也不会互相覆盖，不该避让。
///
/// **「同名」是按文件系统的口径算的，不是按字符串本身。** macOS 默认的 APFS
/// 大小写不敏感（大小写保留）：`X (…).mp4` 与 `x (…).mp4` 是**同一个文件**，
/// 核心写出后者就是覆盖前者。所以这里名字比对的每一处（认领时的前缀判据、
/// 避让时的目录清单与本批占用表）都折叠大小写，见 `sameName`。
///
/// 单独成类型而不是挂在 `CoreManager` 上，是因为命令行探针也要用这套逻辑，
/// 而探针不需要为了算个名字去拉起一个 `CoreManager`。
public enum OutputNaming {

    // MARK: - 名字

    /// 核心会把这个任务写成什么文件名。**只用于显示与日志，不要拿它去目录里找文件**
    /// —— 角标在任务回复和实际文件名之间会不一致（见类型说明），要用 `locate`。
    ///
    /// - Parameter saveFilename: 提交任务时 `TaskNewReq.save_filename` 传的那个值。
    /// - Parameter ext: 核心按「是否仅音频」定扩展名（`.mp4` / `.mp3`），
    ///   调用方知道就传准，不知道就用默认值。
    public static func coreName(
        videoBadge: String,
        codec: String,
        audioBadge: String,
        api: String,
        saveFilename: String = "",
        ext: String = "mp4"
    ) -> String {
        let stem = saveFilename.isEmpty ? "" : sanitized(saveFilename)
        return "\(stem) (\(videoBadge), \(codec), \(audioBadge), \(api)).\(ext)"
    }

    // MARK: - 定位

    /// 这次提交的产物会是什么扩展名。
    ///
    /// 规则只有一条依据：**扩展名由提交时的 `audio_only` 决定** —— 核心对仅音频
    /// 恒写 `.mp3`、对视频恒写 `.mp4`，实测没有第三种。定成一处的理由是它同时是
    /// 「提交前避让」（`availableStem`）与「完成后定位」（`newestMatch`）的判据：
    /// 两边必须用同一个值，否则会出现「避让时按 mp3 放行、定位时按 mp4 去找」这种
    /// 自相矛盾的行为。
    public static func ext(audioOnly: Bool) -> String {
        audioOnly ? "mp3" : "mp4"
    }

    /// 从一份文件名清单里挑出主干为 `stem` 的产物，返回**最新**的那个文件名。
    ///
    /// 清单由调用方读好传进来，而不是由这里去读目录：读目录是要碰磁盘的，
    /// 得由调用方决定它在哪个线程上发生（App 的调用点全在主 actor 上，
    /// 不希望它卡在界面里）。
    ///
    /// - Parameters:
    ///   - directory: 这些名字所在的目录。判新旧要 stat，得拿绝对路径，
    ///     不能拿文件名去 stat（那会落到进程的当前目录上，静默比错）。
    ///   - ext: 期望的扩展名，传 `ext(audioOnly:)` 的结果。**必须传**：
    ///     主干同名而扩展名不同的两份产物是可以共存的（见 `matches`），
    ///     不筛扩展名就会把另一种的那份认成这个任务的产物 —— App 重启后
    ///     内存里的对照表已空，只能靠这一趟重新认领，认错就把「在访达中显示」
    ///     指到另一个文件上（不丢文件，但指错）。
    public static func newestMatch(
        in names: [String],
        stem: String,
        directory: URL,
        ext: String
    ) -> String? {
        guard !stem.isEmpty else { return nil }
        return names.filter { matches(name: $0, stem: stem, ext: ext) }.max { a, b in
            modified(directory.appendingPathComponent(a))
                < modified(directory.appendingPathComponent(b))
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// 目录里的某个名字，是不是「主干为 `stem` 的那个产物」。
    ///
    /// **扩展名也算判据**（`ext` 传了的话），而且必须算：核心的扩展名不是随手写
    /// 的，是**由提交时的 `audio_only` 定的** —— 仅音频恒为 `.mp3`、视频恒为
    /// `.mp4`，实测没有第三种。所以「主干相同、扩展名不同」的两份产物根本不会
    /// 互相覆盖，本来就不该算撞名。不筛扩展名的后果很具体：目录里躺着一个
    /// `T (…).mp4`，用户下一个同名主干但**仅音频**的任务（产物是 `T (…).mp3`），
    /// 避让却以为撞上了，给出 `T (2)` —— 用户看到一个莫名其妙的 `(2)`。
    ///
    /// `ext` 传 nil 表示「不看扩展名」，只给调用方不知道扩展名的场合用（定位
    /// 那一路就是这么调的，那里不筛不影响正确性，只是可能多认一个同主干的别的
    /// 扩展名的产物）。
    ///
    /// 光比前缀是不够的，有一条真实的误判路径：撞名时我们会把主干改成
    /// `X (2)`，它的产物叫 `X (2) (角标…).mp4`，**前缀同样是 `X (`**。要是把它
    /// 也算成主干 `X` 的东西：
    ///
    /// - 定位会认错文件（拿到的是另一个任务的产物）；
    /// - 避让会误以为 `X` 已被占用，把新主干改成 `X (2)`，而
    ///   `X (2) (角标…).mp4` 正躺在那儿等着被核心**静默覆盖**。
    ///
    /// 所以判据是：去掉扩展名后必须以 `)` 收尾，且撞名后缀的形状
    /// （**纯数字 + `) (`**）不能出现在开头。
    ///
    /// 为什么不用「括号里不许有括号」这条更简单的判据：角标自己就可能带括号
    /// —— 实测见过 `unknown (0)`，那条会把正常的产物全部判掉。
    ///
    /// 代价说明：撞名后缀只可能是我们自己生成的纯数字形式，所以判据只卡数字。
    /// 要是主干的尾部长得跟撞名后缀一样（用户标题就叫 `X (a.b)`），会被误判成
    /// 更长的那个主干 —— 后果只是多加一个后缀，不会盖掉谁。
    ///
    /// **前缀比对折叠大小写。** 目录里躺着的 `MY VIDEO (…).mp4` 与这次的
    /// `My video` 在大小写不敏感的卷上就是同一个文件：比成「不是」的话，避让会
    /// 放行、核心写完就把它盖了。做过英文视频的用户很容易撞上这条 —— B 站标题
    /// 改个大小写很常见。
    ///
    /// 副作用说明（只在大小写敏感的卷上才看得见）：同一个主干的两份旧产物
    /// （`X (…).mp4` 与 `x (…).mp4`）会被一起认出来，`newestMatch` 取其中较新的
    /// 那份。提交侧已经不会放行这种撞名（后下的一条会被改成 `x (2)`），
    /// 所以这只会影响修好之前就已经躺在目录里的老文件。
    public static func matches(name: String, stem: String, ext: String? = nil) -> Bool {
        guard !stem.isEmpty else { return false }

        // 扩展名折叠大小写比，理由同 `sameName`：卷不区分大小写时
        // `T (…).MP4` 与 `T (…).mp4` 是同一个文件，比成「不是」会放行、核心
        // 写完就把它盖了。
        if let ext, !sameName((name as NSString).pathExtension, ext) { return false }

        let prefix = "\(stem) ("

        let base = (name as NSString).deletingPathExtension
        guard base.hasSuffix(")") else { return false }

        // 在**去掉扩展名**的结果上找前缀，再按匹配到的区间切尾巴。
        // 不按 `prefix.count` 切：大小写折叠偶尔会改变字符数（`ß` / `SS` 这类），
        // 长度对不上会把尾巴切歪，判据就跟着错。
        guard let head = base.range(of: prefix, options: [.caseInsensitive, .anchored]) else {
            return false
        }
        let inner = base[head.upperBound...]
        return inner.range(of: #"^\d+\) \("#, options: .regularExpression) == nil
    }

    /// 两个名字在**文件系统眼里**是不是同一个。
    ///
    /// 用 Foundation 的大小写不敏感比对而不是 `lowercased()` 相比：前者和
    /// `matches` 用的是同一套折叠规则（含 Unicode 规范等价），两边结论不会打架。
    ///
    /// 为什么不做「先探测卷是否大小写敏感再决定怎么比」：探测要么往用户的下载目录里
    /// 写临时文件（有副作用），要么读 `volumeSupportsCaseSensitiveNames` 再把布尔量
    /// 一路串进 `matches` / `availableStem` / 探针。而折叠的代价是**单向**的：
    /// 在大小写敏感的卷上最多多算一个 ` (2)`（虚惊一场，文件还是好好的）；
    /// 不折叠的代价是在默认的 APFS 上**静默盖掉用户的文件**。所以一律折叠。
    static func sameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }

    // MARK: - 撞名避让

    /// 给主干挑一个不会撞上的可用名：优先原名，撞了就依次试 ` (2)`、` (3)`…。
    ///
    /// - Parameters:
    ///   - ext: 这次要下的产物的扩展名，由提交时的 `audio_only` 定：仅音频传
    ///     `.mp3`、视频传 `.mp4`。**判据按扩展名分组**，见 `matches`：主干同名
    ///     但扩展名不同的两份产物不会互相覆盖，不该为此加 ` (2)`。
    ///   - taken: **本次运行已经占用的主干**。目录里查不到的也得算进来：
    ///     上一个任务可能刚提交、文件还没落盘，这时磁盘上看不出冲突。
    ///   - existingNames: 目录里现有的文件名（调用方读一次传进来，避免每挑一次
    ///     就读一遍目录）。
    /// - Returns: 可用的主干名；试到 999 还撞就返回 nil（调用方按这一项失败处理）。
    public static func availableStem(
        _ stem: String,
        ext: String,
        taken: Set<String>,
        existingNames: [String]
    ) -> String? {
        // `taken` 这一路**只看主干、不分扩展名**，保持原样：同一批里两个分P
        // 的主干同名时，先提交的那个必须挡住后一个 —— 那时磁盘上还没有文件
        // 可查（前一个在下载中），`existingNames` 那一路帮不上忙，按扩展名放行
        // 就没有别的屏障了。扩展名只放宽「目录里已存在的文件」这一路。
        //
        // `taken` 也要折叠大小写比：同一批里两个分P 的标题只差大小写时，
        // 先提交的那个必须挡住后一个，否则两个任务算出只差大小写的主干、互相覆盖。
        func isFree(_ candidate: String) -> Bool {
            if taken.contains(where: { sameName($0, candidate) }) { return false }
            return !existingNames.contains {
                matches(name: $0, stem: candidate, ext: ext)
            }
        }

        if isFree(stem) { return stem }
        var n = 2
        while n <= 999 {
            let candidate = "\(stem) (\(n))"
            if isFree(candidate) { return candidate }
            n += 1
        }
        return nil
    }

    // MARK: - 清洗

    /// 文件名主干能占多少**字节**。
    ///
    /// 按字节而不是字符算：文件名长度限制（APFS/HFS+ 都是 255）是按 UTF-8 字节
    /// 计的，而一个汉字 3 字节 —— 按 120 字符截断能到 360 字节，核心再补上
    /// ` (高清 1080P, HEVC, 极高音质, WEB).mp4` 那一段就写不进去了。
    /// 150 字节留够了角标和撞名后缀的位置。
    private static let maxStemBytes = 150

    /// 标题会直接进文件名，得挡掉路径分隔符、会让文件变隐藏的前导点，以及超长。
    ///
    /// `/` 不是「不好看」而已：实测主干名里带 `/` 会让 ffmpeg 失败、任务转
    /// TASK_ERROR 且**不产出文件**。`\` 和 `:` 在别的文件系统上同理会出事。
    public static func sanitized(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\u{0}"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let undotted = cleaned.drop(while: { $0 == "." })
        return truncate(String(undotted), toBytes: maxStemBytes)
    }

    /// 按 UTF-8 字节截断，且不切碎一个字符。
    private static func truncate(_ text: String, toBytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var out = ""
        var used = 0
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > limit { break }
            out.append(ch)
            used += n
        }
        return out
    }
}
