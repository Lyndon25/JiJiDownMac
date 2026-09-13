import JiJiKit
import JiJiProtos
import SwiftUI

struct AccountView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 取用户信息失败必须显出来（见 `AppModel.userError`）：那条失败
                // **不会**改动 `user`，所以页面上其他地方什么变化都没有 —— 不说
                // 的话，用户点了「刷新」看到界面纹丝不动，只会以为按钮坏了；
                // 而没登录时更糟：界面按「未登录」显示，他会以为自己被登出了，
                // 跑去重新扫码（已登录时核心又不给二维码，撞上一句更莫名其妙的
                // 报错）。所以这段话的重点是**把「没问到」和「真的没登录」分开**。
                if let userError = model.userError {
                    UserErrorNotice(reason: userError, hasPrevious: model.user != nil)
                }
                if model.isLoggedIn, let user = model.user {
                    LoggedInCard(user: user)
                } else {
                    LoginCard(method: $model.loginMethod)
                }
                AboutAuth()
            }
            .padding(18)
            .frame(maxWidth: 640, alignment: .leading)
        }
        // 进页面就自动取一张二维码，省掉一次点击。
        // 内部会先等核心就绪再取 —— 视图出现时核心通常还没启动完。
        .task { await model.beginLoginIfNeeded() }
    }
}

// MARK: - 取用户信息失败

/// 「这次没取到用户信息」的说明条。
///
/// 样式和 TaskListView 的 `NoticeLine`、ParseView 的 `NoteBox` 是一套，但那两个
/// 都是 private（跨文件用不了），这里按本文件的需要再内联一份。
private struct UserErrorNotice: View {
    let reason: String
    /// 这次失败之前手里有没有一份用户信息。有的话，下面那张卡显示的是上一次的
    /// 结果，措辞必须和「什么都没有」时不一样 —— 前者是「没有变」，后者是
    /// 「这次没问到，所以只能按未登录显示」。
    let hasPrevious: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private var text: LocalizedStringKey {
        hasPrevious ? """
            这次没取到用户信息：\(reason)

            上面那张卡是上一次取到的结果，**核心那边的登录态并没有变** —— 不用
            重新登录。多半只是这一次请求没成：核心意外退出后自己重启（最长要等
            60 秒就绪），或者一次瞬时的连接失败。点「刷新」再试一次；一直不成
            就去「核心」页看它是不是起不来了。
            """ : """
            这次没取到用户信息：\(reason)

            手头还没有过一份用户信息，所以下面只能按「未登录」显示。**这不代表
            你的登录态没了** —— 这次只是没问到，核心那边该是什么样还是什么样。
            多半是核心还没就绪（它意外退出后自己重启，最长要等 60 秒），或者一次
            瞬时的连接失败。点「刷新」再试一次；一直不成，或者核心页显示它起不来，
            再按下面的登录流程走。
            """
    }
}

// MARK: - 已登录

private struct LoggedInCard: View {
    @Environment(AppModel.self) private var model
    let user: Jijidown_Core_UserInfoReply

    var body: some View {
        HStack(spacing: 14) {
            if let face = NSImage(data: user.face) {
                Image(nsImage: face).resizable().frame(width: 56, height: 56).clipShape(.circle)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().frame(width: 56, height: 56).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(user.uname).font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    Text("UID \(user.mid)").font(.caption).foregroundStyle(.secondary)
                    if user.vipStatus {
                        Text(user.vipLabelText.isEmpty ? "大会员" : user.vipLabelText)
                            .font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.pink.opacity(0.18), in: Capsule())
                    }
                    if !user.badge.isEmpty {
                        Text(user.badge).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("刷新") { Task { await model.refreshUser() } }
                .controlSize(.small)
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 登录

private struct LoginCard: View {
    @Environment(AppModel.self) private var model
    @Binding var method: LoginMethod

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $method) {
                ForEach(LoginMethod.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch method {
            case .qr: QRLoginPane()
            case .cookie: CookieLoginPane()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 扫码

private struct QRLoginPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                qrBox
                VStack(alignment: .leading, spacing: 10) {
                    statusLine

                    // 选择器必须内联在 @Bindable 作用域里。写进独立的计算属性
                    // 会每次访问都新建一个 @Bindable，绑定不可靠（表现为
                    // 选中的项和模型里的值对不上）。
                    Picker("登录通道", selection: $model.loginAPI) {
                        Text("云视听小电视（Web + TV + APP）").tag(Jijidown_Core_LoginQRCodeAPI.tv)
                        Text("网页版（仅 Web）").tag(Jijidown_Core_LoginQRCodeAPI.web)
                    }
                    .pickerStyle(.radioGroup)
                    .font(.callout)

                    buttons
                    if let err = model.loginError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            Text("扫码由核心完成，登录凭据由核心保管，App 不经手。")
                .font(.caption).foregroundStyle(.tertiary)
        }
        // 换通道后自动重取。**只在已经有码时才重取** —— 否则 Picker 初始化
        // 时的写值会误触发一次，和 .task 的开场请求撞在一起形成请求风暴，
        // 把核心的客户端超时挤爆（实测过：核心日志里 TV/WEB 请求交替刷屏，
        // 全是 context deadline exceeded）。
        .onChange(of: model.loginAPI) {
            guard model.qrPNG != nil, !model.isLoggingIn else { return }
            Task { await model.beginLogin(api: model.loginAPI) }
        }
    }

    /// 二维码本体。固定尺寸占位，避免取码前后布局跳动。
    private var qrBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.white)
                .frame(width: 200, height: 200)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))

            if let png = model.qrPNG, let image = NSImage(data: png) {
                Image(nsImage: image)
                    .interpolation(.none)   // 二维码必须最近邻缩放，否则糊到扫不出
                    .resizable()
                    .frame(width: 180, height: 180)
            } else if model.isLoggingIn {
                ProgressView().controlSize(.small)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("没有二维码")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.loginStatusText.isEmpty ? "未开始" : model.loginStatusText)
                .font(.callout.weight(.medium))
                .foregroundStyle(model.isLoggedIn ? .green : .primary)

            // 倒计时：B 站二维码 180 秒失效，剩不到一半就变橙色提醒。
            if model.qrPNG != nil, model.qrSecondsLeft != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = model.qrSecondsLeft ?? 0
                    Text(left > 0 ? "二维码 \(left) 秒后失效" : "二维码已过期，点刷新重取")
                        .font(.caption)
                        .foregroundStyle(left > 60 ? Color.secondary : Color.orange)
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.beginLogin() }
            } label: {
                Label(model.qrPNG == nil ? "获取二维码" : "刷新二维码",
                      systemImage: "arrow.clockwise")
            }
            .disabled(!model.core.phase.isRunning)

            if model.isLoggingIn {
                Button("取消") { model.cancelLogin() }
            }
        }
    }
}

// MARK: - Cookie 导入

private struct CookieLoginPane: View {
    @Environment(AppModel.self) private var model

    private static let required = ["DedeUserID", "DedeUserID__ckMd5", "SESSDATA",
                                   "bili_jct", "sid", "buvid3"]

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 12) {
            Text("从浏览器里复制 B 站的 Cookie，粘贴到下面。")
                .font(.callout)

            Text("需要的字段：\(Self.required.joined(separator: "、"))")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)

            TextEditor(text: $model.cookieInput)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 96)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            // 顺序和校验顺序一致：cookies 必填 → token 可选（`importCookie` 也是
            // 先校验 cookies 再取 token）。
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("AccessToken（可选）").font(.callout)
                    Spacer()
                    Toggle("明文显示", isOn: $model.revealAccessToken)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }

                // 明暗两个输入框是**两个控件**而不是给同一个框改属性：macOS 上
                // SecureField 和 TextField 的内部实现不同，原地切换不保证
                // 光标位置与已输入内容的表现一致，换控件最省事也最可预期。
                // 状态（是否明文、输入内容）都在 AppModel 上，本机没有 @State。
                Group {
                    if model.revealAccessToken {
                        TextField("粘贴 AccessToken", text: $model.accessTokenInput)
                    } else {
                        SecureField("粘贴 AccessToken", text: $model.accessTokenInput)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))

                Text("""
                    这是**可选的**，不上 TV / APP 接口就不用填。官方客户端的 Cookie 导入\
                    界面写着它「用于登录 TV、APP 接口」，但**本项目没有验证过**这件事 ——\
                    本机配到的它是空的，而 TV / APP 现在一律在取播放地址那一步失败。\
                    填了能不能通，未知；所以别把「填了就能下 TV 无水印」当成结论。
                    """)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await model.importCookie() }
                } label: {
                    if model.isImportingCookie {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                }
                // 判据收在 `canImportCookie` 里：它会把纯空白的输入也判成「空」，
                // 否则按钮亮着、点下去静默返回，用户看不到任何反馈。
                .disabled(!model.canImportCookie)

                if let err = model.loginError {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Label {
                Text("""
                    这是你的登录凭据，只通过本地 gRPC 交给核心。App 自己不落盘：日志里\
                    不写，导入失败时错误文本里出现的凭据会被隐去。

                    但要说清楚一件事：**登录态会落进 \
                    `~/.config/JiJiDown/config.yaml`** —— 核心自己把 `user-info` 那几项\
                    写回去，而本客户端每次启动都会重写这份配置，重写时把这几个字段\
                    **原样抄回去**：不解析、不新增，但不抄回去就等于每次启动都把你登出。\
                    所以这份文件里带着你的凭据，备份、分享、跨机器同步它之前先想一下。\
                    不想要这一步就别登录 —— 只是核心的下载接口在授权门后面，不登录\
                    就用不了。
                    """)
            } icon: {
                Image(systemName: "lock.shield")
            }
            .font(.caption).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 说明

private struct AboutAuth: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("关于登录", systemImage: "info.circle")
                .font(.subheadline.weight(.medium))

            Text("""
                核心只提供两种登录途径：扫码，和导入 Cookie。没有短信或密码登录 —— \
                这是核心的能力边界，不是这个界面省略了。

                登录后核心会拿 access_token 去 sabe.cc 换授权（日志里的 \
                `[license] Update License`）。核心的下载与视频详情接口都在授权门后面，\
                所以不登录时「解析」会直接失败。
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
}
