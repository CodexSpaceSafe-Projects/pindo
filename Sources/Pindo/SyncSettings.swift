import SwiftUI

struct SyncSettings: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var controller: CloudSyncController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Cloudflare", systemImage: "cloud")
                .font(.system(size: 13, weight: .medium))
            Text(l10n("Cloudflare 同步正在开发，当前仅保存在本机。"))
            Text(l10n("旧云服务已停用。本机资料、离线修改和恢复信息会继续保留。"))
                .foregroundStyle(.secondary)
            Text(l10n("可在备份设置中导出待办、分组和备注。"))
                .foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
}
