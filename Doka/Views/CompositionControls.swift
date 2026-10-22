import SwiftUI

struct CompositionControls: View {
    @ObservedObject var composition: CompositionModel
    @ObservedObject var camera: CameraController
    @ObservedObject var model: CameraModel
    @State private var confirmUpload = false
    @State private var showDetails = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if composition.isAnalyzing { composition.reset() }
                else if !composition.isAuthenticated { composition.showLogin = true }
                else { confirmUpload = true }
            } label: {
                Label(composition.isAnalyzing ? "取消" : "AI 构图", systemImage: "viewfinder")
                    .font(.subheadline.weight(.semibold))
            }.disabled(!camera.isRunning)
            if composition.isAnalyzing { ProgressView().controlSize(.small) }
            Text(composition.guidance).font(.caption).foregroundStyle(composition.isAligned ? Color.green : Color.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if composition.result != nil {
                Button { showDetails = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("构图说明与推荐滤镜")
                Button { composition.reset() } label: { Image(systemName: "xmark.circle") }
                    .accessibilityLabel("清除构图引导")
            }
        }.frame(minHeight: 36)
        .confirmationDialog("发送当前画面进行 AI 分析？", isPresented: $confirmUpload, titleVisibility: .visible) {
            Button("发送并分析") { composition.analyze(zoomFactor: Double(camera.zoomFactor)) }
        } message: {
            Text("画面会发送到 Doka 服务，可能消耗账号的构图次数。请避免拍入不希望上传的内容。")
        }
        .sheet(isPresented: $composition.showLogin, onDismiss: { composition.refreshLogin() }) {
            AILoginView(composition: composition)
        }
        .sheet(isPresented: $showDetails) {
            NavigationStack {
                List {
                    if let result = composition.result {
                        if !result.reason.isEmpty { Section("构图说明") { Text(result.reason) } }
                        Section("推荐滤镜") {
                            if result.recommendations.isEmpty { Text("此次分析没有返回滤镜推荐").foregroundStyle(.secondary) }
                            ForEach(Array(result.recommendations.enumerated()), id: \.offset) { _, recommendation in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(recommendation.filterName).font(.headline)
                                    Text(recommendation.reason).font(.subheadline).foregroundStyle(.secondary)
                                    if let filter = matchingFilter(recommendation.filterName) {
                                        Button("应用滤镜") { model.settings.filterID = filter.id; showDetails = false }
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }.navigationTitle("AI 构图").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showDetails = false } } }
            }
        }
        .alert("AI 构图未完成", isPresented: Binding(
            get: { composition.errorMessage != nil && !composition.showLogin },
            set: { if !$0 { composition.errorMessage = nil } }
        )) { Button("知道了", role: .cancel) { composition.errorMessage = nil } } message: {
            Text(composition.errorMessage ?? "请重试。")
        }
    }

    private func matchingFilter(_ name: String) -> FilmFilter? {
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return FilmFilter.all.first { $0.name.lowercased().filter { $0.isLetter || $0.isNumber } == key }
    }
}

struct AILoginView: View {
    @ObservedObject var composition: CompositionModel
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var code = ""
    @State private var busy = false
    @State private var cooldownUntil = Date.distantPast
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("使用 Doka 账号登录后，AI 构图会由 Doka 服务分析当前取景画面。可用次数和会员权益由原服务决定。")
                    if let failure = composition.errorMessage { Text(failure).foregroundStyle(.red) }
                }
                Section("手机号登录") {
                    TextField("手机号", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    HStack {
                        TextField("短信验证码", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(ceil(cooldownUntil.timeIntervalSince(context.date))))
                            Button(remaining > 0 ? "\(remaining) 秒" : "获取验证码") { sendCode() }
                                .disabled(busy || phone.isEmpty || remaining > 0)
                        }
                    }
                    Button { login() } label: {
                        HStack { if busy { ProgressView() }; Text("登录") }
                    }.disabled(busy || phone.isEmpty || code.isEmpty)
                }
                if let message { Section { Text(message).font(.subheadline) } }
                Section {
                    Link("Doka 服务隐私政策", destination: URL(string: "https://www.yindoka.com/web/android/privacy_policy")!)
                    Text("手机号和验证码仅用于向 Doka 发起登录。登录凭证保存在此设备的钥匙串中。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("登录 Doka").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() }.disabled(busy) } }
        }
    }

    private func sendCode() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await AIService.shared.sendCode(phone: phone)
                cooldownUntil = Date().addingTimeInterval(60)
                message = "验证码已发送"
            } catch { message = error.localizedDescription }
        }
    }

    private func login() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await AIService.shared.login(phone: phone, code: code)
                composition.refreshLogin()
                composition.errorMessage = nil
                dismiss()
            } catch { message = error.localizedDescription }
        }
    }
}

struct CompositionOverlay: View {
    @ObservedObject var composition: CompositionModel
    var body: some View {
        GeometryReader { geometry in
            if let rect = composition.trackedRect {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(composition.isAligned ? Color.green : .yellow, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                    .frame(width: rect.width * geometry.size.width, height: rect.height * geometry.size.height)
                    .position(x: rect.midX * geometry.size.width, y: rect.midY * geometry.size.height)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
