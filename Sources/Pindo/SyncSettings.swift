import SwiftUI

struct SyncSettings: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var controller: CloudSyncController
    @State private var endpoint="https://pindo-sync-v3-staging.zhchain.workers.dev"
    @State private var bootstrapSecret=""
    @State private var pairing=""
    @State private var confirmDisconnect=false
    @State private var showCreate=false
    @State private var showDevices=false
    var body: some View {
        VStack(alignment:.leading,spacing:16){
            Label("Cloudflare",systemImage:"lock.icloud").font(.headline)
            Text(l10n("待办、分组和备注在本机加密后同步。恢复密钥只保存在设备上。"))
                .foregroundStyle(.secondary)
            GroupBox{
                VStack(alignment:.leading,spacing:10){
                    HStack{if controller.isSyncing{ProgressView().controlSize(.small)};Text(l10n(controller.status))}
                    if let date=controller.lastSyncDate{LabeledContent(l10n("最近同步")){Text(date,format:.dateTime.month().day().hour().minute())}}
                    if controller.isConfigured{
                        Text(controller.endpoint).font(.caption).textSelection(.enabled)
                        HStack{
                            Button(l10n("立即同步")){controller.syncNow()}.disabled(controller.isSyncing)
                            Button(l10n("配对另一台设备")){controller.createInvitation()}.disabled(controller.isSyncing)
                            Button(l10n("管理设备")){showDevices.toggle();if showDevices{controller.loadDevices()}}
                        }
                        Button(l10n("停用云同步")){confirmDisconnect=true}
                    }else{
                        Text(l10n("停用时仍保留本机资料、恢复信息和待上传修改。"))
                        Button(l10n("重新连接已保存的资料库")){controller.reconnect()}
                    }
                    if controller.hasPendingConnection{Button(l10n("继续未完成的连接")){controller.resumePending()}.disabled(controller.isSyncing)}
                }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
            }
            if let invitation=controller.invitation{
                GroupBox(l10n("配对信息")){
                    VStack(alignment:.leading,spacing:10){
                        Text(l10n("此信息包含恢复密钥。请通过安全通道交给另一台设备，配对凭据十分钟内有效且只能使用一次。"))
                        SecureField(l10n("配对信息"),text:.constant(invitation))
                        Button(l10n("复制配对信息")){controller.copyInvitation()}
                    }.padding(6)
                }
            }
            if showDevices{
                GroupBox(l10n("管理设备")){
                    VStack(alignment:.leading,spacing:10){
                        ForEach(controller.deviceList){device in
                            HStack{Text(String(device.id.prefix(8))).monospaced();Spacer();if device.revoked_at != nil{Text(l10n("已撤销"))}else{Button(l10n("撤销访问")){controller.revokeDevice(device.id)}}}
                        }
                        Button(l10n("轮换本机访问令牌")){controller.rotateToken()}.disabled(controller.isSyncing)
                        Text(l10n("撤销只阻止之后的云访问；已下载的资料和密钥无法远程收回。"))
                    }.padding(6)
                }
            }
            GroupBox(l10n("加入已有资料库")){
                VStack(alignment:.leading,spacing:10){
                    SecureField(l10n("粘贴另一台设备的配对信息"),text:$pairing)
                    Button(l10n("配对并合并本机资料")){controller.join(invitation:pairing);pairing=""}.disabled(pairing.isEmpty||controller.isSyncing)
                    Text(l10n("切换资料库会保留各库自己的本机副本和离线历史。"))
                }.padding(6)
            }
            DisclosureGroup(l10n("首次初始化自己的服务"),isExpanded:$showCreate){
                VStack(alignment:.leading,spacing:10){
                    TextField(l10n("服务地址"),text:$endpoint)
                    SecureField(l10n("部署者初始化密钥"),text:$bootstrapSecret)
                    Button(l10n("初始化并连接")){controller.create(endpoint:endpoint,bootstrapSecret:bootstrapSecret);bootstrapSecret=""}.disabled(bootstrapSecret.isEmpty||controller.isSyncing)
                    Text(l10n("服务只允许初始化一次。之后的设备通过已有设备配对，不需要部署者密钥。"))
                }.padding(.top,8)
            }
            if let error=controller.errorMessage{Text(error).foregroundStyle(.red).textSelection(.enabled)}
        }.font(.system(size:12))
            .alert(l10n("停用云同步？"),isPresented:$confirmDisconnect){
                Button(l10n("取消"),role:.cancel){}
                Button(l10n("停用云同步"),role:.destructive){controller.disconnect()}
            }message:{Text(l10n("本机资料、恢复信息和离线修改会保留，之后可以继续连接。"))}
    }
}
