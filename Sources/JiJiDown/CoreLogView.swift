import AppKit
import JiJiKit
import SwiftUI

struct CoreLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(model.core.phase.tint).frame(width: 8, height: 8)
                Text(model.core.phase.label).font(.callout)
                if !model.core.coreVersion.isEmpty {
                    Text(model.core.coreVersion)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    model.checkUpdate()
                } label: {
                    if model.isCheckingUpdate {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                // 只防重入，不按核心状态禁用：核心没连上时点它也是有效操作
                // （会得到一句「核心还没连上」），静默吃掉一次点击更糟。
                .disabled(model.isCheckingUpdate)

                Toggle("自动滚动", isOn: $model.autoScroll).toggleStyle(.checkbox)

                Button(coreButtonTitle) {
                    // 判据同样是**进程**：进程还活着就收掉它（`shutdown()` 在这个
                    // 状态里就是一次干净的收尾 —— `client` / 轮询那时都还不存在），
                    // 进程真没了才去启动。按 phase 判的话，下面那三条流全都走不通。
                    if model.core.isCoreProcessRunning {
                        model.shutdown()
                    } else {
                        Task { await model.bootCore() }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if model.hasUpdateNotice {
                UpdateBanner()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            DownloadDirectoryRow()
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.core.log.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: model.core.log.count) {
                    guard model.autoScroll, let last = model.core.log.indices.last else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    /// 核心那颗按钮写什么，判据是**进程实际在不在跑**，不是 `phase`。
    ///
    /// 为什么不能按 `phase`：等就绪超时时 `phase` 是 `.failed`，核心进程却还活着
    /// （它多半只是卡在联网领 license）。按 `phase` 显示的话这颗按钮会写成
    /// 「启动核心」，而点它调用的 `bootCore()` 里 `core.start()` 因为「已有进程
    /// 在跑」早退、紧接着的 `guard core.phase.isRunning` 也不成立 —— 于是**界面
    /// 上唯一这颗核心按钮**从此是空操作，而「下载」页的解析按钮、「任务」页的
    /// 刷新又都被 `phase.isRunning` 禁着，用户除了退出 App 没有第二条路。
    ///
    /// 所以那个状态给的是「强制停止核心」这个出口：收掉卡住的核心 → `phase`
    /// 落到「已停止」→ 按钮变回「启动核心」→ 再点才是一次真正的重新启动。
    /// 启动那几十秒里进程也在跑，但那时 `phase` 是 `.starting`，按钮写「停止核心」
    /// 就是它字面的意思。
    private var coreButtonTitle: String {
        guard model.core.isCoreProcessRunning else { return "启动核心" }
        if case .failed = model.core.phase { return "强制停止核心" }
        return "停止核心"
    }
}

// MARK: - 检查更新

/// 检查更新的结果横幅。
///
/// 三条约束落在实现里：
///
/// 1. **不放任何「更新 / 下载」按钮。** 用户已经定了：只提示，不下载不安装。
///    横幅里出现一个能点的「更新」按钮就等于把这个决定推翻了。
/// 2. changelog 默认折叠 —— 实测有 195 个字，展开着会把日志区挤掉一半。
///    展开后可选中复制（用户要拿去比对就得能复制）。
/// 3. 必须说明它是**核心启动时那次检查的回放，不会重新联网**。不说的话，
///    用户会以为多点几次能查到新东西，然后怀疑按钮坏了。
private struct UpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: model.updateStatus?.symbol ?? "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
                Text(headline)
                    .font(.callout.weight(.medium))
                if let at = model.updateCheckedAt {
                    Text("· \(at.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("关闭") { model.dismissUpdateNotice() }
                    .controlSize(.small)
            }

            if let error = model.updateError {
                // ParseView 里的 ErrorBox 是 private（跨文件用不了），这里内联一份。
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                    // 同上：错误正文是 String 变量，得显式过一遍 markdown。
                    Text(Markdown.inline(error))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !model.updateChangeLog.isEmpty {
                DisclosureGroup(isExpanded: $model.updateChangeLogExpanded) {
                    Text(model.updateChangeLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    Text("更新说明（\(model.updateChangeLog.count) 字）").font(.caption)
                }
                .font(.caption)
            }

            Text("""
                这是**核心启动时那次检查**的结果回放，不是重新联网 —— 反复点内容也一样。\
                本项目只提示，不下载也不安装新版本。
                """)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var tint: Color { model.updateStatus?.tint ?? .red }

    private var headline: String {
        if let status = model.updateStatus { return status.label }
        // 一条都没回来（或流里只有「检查中」）。**不要替核心说「已是最新版本」**，
        // 我们自己也不知道，只能说没拿到结论。
        return "这次没拿到结论"
    }
}

// MARK: - 下载目录

/// 当前下载目录。
///
/// 摆在这里是因为两个真实的症状都指向它：「下完了不知道文件在哪」，以及
/// 产物定位失败时界面上一片安静。目录是只读展示 —— 改它要重写配置并重启核心
/// （`CoreManager.rewriteConfig`），现在没有这个入口。
private struct DownloadDirectoryRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("下载目录").font(.caption).foregroundStyle(.secondary)
                Text(model.core.downloadDirectory.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }

            Spacer()

            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([model.core.downloadDirectory])
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
