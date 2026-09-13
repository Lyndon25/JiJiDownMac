import AppKit
import SwiftUI

@main
struct JiJiDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // 用单例而不是 @State —— 见 AppModel 顶部的说明：CLT 下 @State 的宏不可用。
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup("唧唧") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    delegate.model = model
                    await model.bootCore()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// 退出时务必把核心一起带走。
///
/// 核心是独立进程，App 崩溃或被强退时它不会自己退出，会一直占着 4000 端口；
/// 下次启动就会失败（核心只会报 `External controller gRPC listen error`，
/// 对用户来说毫无线索）。所以这里显式收尾。
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // 传 true：这条路径上 AppKit 马上就会退进程，gRPC 那边做不了优雅关闭。
            model?.shutdown(terminating: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
