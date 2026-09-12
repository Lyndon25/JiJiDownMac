import JiJiKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            StatusBar()
            Divider()
            TabView(selection: $model.tab) {
                ParseView()
                    .tabItem { Label(MainTab.parse.rawValue, systemImage: MainTab.parse.symbol) }
                    .tag(MainTab.parse)
                TaskListView()
                    .tabItem { Label(MainTab.tasks.rawValue, systemImage: MainTab.tasks.symbol) }
                    .tag(MainTab.tasks)
                AccountView()
                    .tabItem { Label(MainTab.account.rawValue, systemImage: MainTab.account.symbol) }
                    .tag(MainTab.account)
                CoreLogView()
                    .tabItem { Label(MainTab.core.rawValue, systemImage: MainTab.core.symbol) }
                    .tag(MainTab.core)
            }
            .padding(.top, 8)
        }
    }
}

/// 顶部状态条：核心状态 + 服务器信息 + 登录态。
private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.core.phase.tint)
                .frame(width: 8, height: 8)

            Text(model.core.phase.label)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            if model.core.phase.isRunning {
                if !model.serverName.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(model.serverName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !model.serverOS.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(model.serverOS)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Label(
                model.isLoggedIn ? (model.user?.uname ?? "已登录") : "未登录",
                systemImage: model.isLoggedIn ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle.badge.questionmark"
            )
            .font(.callout)
            .foregroundStyle(model.isLoggedIn ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
