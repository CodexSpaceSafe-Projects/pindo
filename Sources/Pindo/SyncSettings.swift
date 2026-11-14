import AppKit
import SwiftUI

struct SyncSettings: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var controller: CloudSyncController
    @State private var editing = false
    @State private var endpoint = "https://s3.bitiful.net"
    @State private var bucket = ""
    @State private var region = "cn-east-1"
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var recoveryKey = ""
    @State private var copiedKey = false
    @State private var formError: String?
    @State private var confirmDisconnect = false
    @State private var createVault = false
    @State private var generatedRecoveryKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(l10n("客户端端到端加密已启用"), systemImage: "lock.shield")
                .font(.system(size: 13, weight: .medium))
            Text(l10n("使用你自己的缤纷云账号；云端只保存加密后的待办、分组和备注。")).foregroundStyle(.secondary)
            Text(l10n("应用运行时每 30 秒检查变化，修改后自动尝试同步；离线时仍可使用，联网后重试。")).foregroundStyle(.secondary)
            Text(l10n("新版同步会暂停旧版设备的云同步，请先将所有设备升级到 0.3 或更新版本。"))
                .foregroundStyle(.secondary)

            if controller.isConfigured { connectionStatus }
            if !controller.isConfigured || editing { configurationForm }
            if let error = formError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let error = controller.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .font(.system(size: 12))
        .onAppear { loadConfiguration() }
        .onDisappear { clearSecrets() }
        .alert(l10n("断开云同步？"), isPresented: $confirmDisconnect) {
            Button(l10n("取消"), role: .cancel) {}
            Button(l10n("断开同步"), role: .destructive) {
                do {
                    try controller.disconnect()
                    editing = false
                    clearSecrets()
                } catch { formError = l10n.error(error) }
            }
        } message: {
            Text(l10n("本机保存的同步凭据将被移除。本地待办和云端资料均会保留；重新连接需要原恢复密钥。"))
        }
    }

    private var connectionStatus: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let configuration = controller.configuration {
                    LabeledContent(l10n("存储桶"), value: configuration.bucket)
                    LabeledContent(l10n("服务地址"), value: configuration.endpoint)
                }
                HStack {
                    if controller.isSyncing {
                        ProgressView().controlSize(.small)
                        Text(l10n(controller.phase.rawValue))
                    } else if controller.phase == .synced, let date = controller.lastSyncDate {
                        Text(l10n("最近同步"))
                        Spacer()
                        Text(date, format: .dateTime.month().day().hour().minute().second())
                    } else {
                        Text(l10n(controller.phase.rawValue))
                    }
                }.foregroundStyle(.secondary)
                HStack {
                    Button(l10n("立即同步")) { controller.syncNow() }.disabled(controller.isSyncing)
                    Button(l10n("更改配置")) { loadConfiguration(); editing = true }
                    Spacer()
                    Button(l10n("断开同步")) { confirmDisconnect = true }
                }
            }.padding(9)
        }
    }

    private var configurationForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n("在缤纷云创建私有存储桶，并为同步创建仅可访问该存储桶的子用户凭据。")).foregroundStyle(.secondary)
                    Link(l10n("打开缤纷云控制台"), destination: URL(string: "https://console.bitiful.com/")!)
                    LabeledContent(l10n("存储桶")) { TextField(l10n("存储桶名称"), text: $bucket) }
                    LabeledContent(l10n("服务地址")) { TextField("https://s3.bitiful.net", text: $endpoint) }
                    LabeledContent(l10n("服务区域")) { TextField("cn-east-1", text: $region) }
                    LabeledContent("Access Key") { TextField("Access Key", text: $accessKey) }
                    LabeledContent("Secret Key") { SecureField("Secret Key", text: $secretKey) }
                }.padding(9)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n("恢复密钥")).fontWeight(.medium)
                    Text(l10n("首次连接可生成密钥；其他设备请填写同一密钥。密钥丢失后，无法解密云端资料。")).foregroundStyle(.secondary)
                    SecureField(l10n("64 位十六进制恢复密钥"), text: $recoveryKey)
                        .onChange(of: recoveryKey) { _, value in
                            copiedKey = false
                            if value != generatedRecoveryKey { createVault = false }
                        }
                    Toggle(l10n("创建新的同步资料库"), isOn: $createVault)
                    Text(l10n("加入已有资料库时，找不到资料会报错，不会自动创建空库。首次使用请生成新密钥并选择创建。"))
                        .foregroundStyle(.secondary)
                    Text(l10n("首次连接新资料库会合并当前本机待办；返回已连接过的资料库会恢复该库的本机副本与离线历史。"))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(l10n("生成新密钥"), action: generateKey)
                        Button(l10n(copiedKey ? "已复制密钥" : "复制密钥"), action: copyKey)
                            .disabled(recoveryKey.isEmpty)
                    }
                    Text(l10n("凭据和恢复密钥保存在本机钥匙串，不会随待办上传。")).foregroundStyle(.secondary)
                }.padding(9)
            }
            HStack {
                Button(l10n("保存并连接"), action: connect).disabled(!canConnect)
                if controller.isConfigured {
                    Button(l10n("取消")) { editing = false; clearSecrets() }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var canConnect: Bool {
        !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !secretKey.isEmpty && !recoveryKey.isEmpty
    }

    private func loadConfiguration() {
        if let configuration = controller.configuration {
            endpoint = configuration.endpoint
            bucket = configuration.bucket
            region = configuration.region
        }
    }

    private func connect() {
        do {
            try controller.configure(
                configuration: BitifulConfiguration(endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    region: region.trimmingCharacters(in: .whitespacesAndNewlines)),
                credentials: BitifulCredentials(accessKey: accessKey.trimmingCharacters(in: .whitespacesAndNewlines), secretKey: secretKey),
                recoveryKey: recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines), createIfMissing: createVault)
            editing = false
            clearSecrets()
        } catch { formError = l10n.error(error) }
    }

    private func generateKey() {
        do {
            let key = try SyncEncryption.generateKey()
            generatedRecoveryKey = key; recoveryKey = key
            createVault = true
            formError = nil
        } catch { formError = l10n.error(error) }
    }

    private func copyKey() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copiedKey = pasteboard.setString(recoveryKey, forType: .string)
        if !copiedKey { formError = l10n("未能复制恢复密钥。") }
    }

    private func clearSecrets() {
        accessKey = ""
        secretKey = ""
        recoveryKey = ""
        copiedKey = false
        createVault = false
        generatedRecoveryKey = nil
        formError = nil
    }
}
