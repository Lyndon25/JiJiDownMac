import JiJiKit
import JiJiProtos
import SwiftUI

struct AccountView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                .disabled(model.cookieInput.isEmpty
                          || model.isImportingCookie
                          || !model.core.phase.isRunning)

                if let err = model.loginError {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Label("这是你的登录凭据。App 不会把它写进配置或日志，只通过本地 gRPC 交给核心。",
                  systemImage: "lock.shield")
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
