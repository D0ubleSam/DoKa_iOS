import SwiftUI
import PhotosUI

struct CameraScreen: View {
    @StateObject private var model = CameraModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        CameraContent(model: model, camera: model.camera)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && !model.isEditing { model.camera.start() }
                else { model.camera.stop(); model.composition.reset() }
            }
            .onAppear { model.camera.start() }
            .onDisappear { model.camera.stop(); model.composition.reset() }
    }
}

private struct CameraContent: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var camera: CameraController
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showAdjustments = false
    @State private var showSettings = false
    @State private var showLatest = false
    @State private var focusLocation: CGPoint?
    @State private var focusTask: Task<Void, Never>?
    private let accent = Color(red: 0.97, green: 0.80, blue: 0.30)

    var body: some View {
        VStack(spacing: 12) {
            header
            viewfinder
            CompositionControls(composition: model.composition, camera: camera, model: model)
            zoomControls
            FilmStrip(settings: $model.settings)
            captureControls
            Text(model.notice ?? "拍摄 · 胶片 · 调色")
                .font(.caption).foregroundStyle(.secondary).frame(height: 18)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
        .background(Color(white: 0.045)).tint(accent)
        .sheet(isPresented: $showAdjustments) {
            AdjustmentSheet(model: model, camera: camera).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) {
            settingsSheet.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showLatest) {
            VStack(spacing: 20) {
                if let photo = model.latestPhoto {
                    Image(uiImage: photo).resizable().scaledToFit()
                }
                Text("最近一次拍摄").font(.headline)
                Text("\(model.notice ?? "保存状态请查看提示")").foregroundStyle(.secondary)
                Button("再次保存") { model.retrySaveLastPhoto() }.disabled(model.isSaving)
                Button("完成") { showLatest = false }
            }.padding()
        }
        .fullScreenCover(isPresented: $model.isEditing, onDismiss: { model.closeEditor() }) {
            PhotoEditor(model: model)
        }
        .alert("未能完成", isPresented: Binding(get: { model.errorMessage != nil && !model.isEditing }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
            Button("系统设置") { openSettings() }
        } message: { Text(model.errorMessage ?? "请重试。") }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            model.beginImport()
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw ImagingError.decodeFailed }
                    model.importPhoto(data)
                } catch { model.importFailed(error) }
                selectedPhoto = nil
            }
        }
        .onChange(of: camera.errorMessage) { _, message in
            if camera.isRunning, let message { model.errorMessage = message }
        }
        .onChange(of: camera.position) { _, _ in model.composition.reset() }
        .onChange(of: camera.state) { _, state in
            if state != .ready { model.composition.reset() }
        }
    }

    private var header: some View {
        HStack {
            Text("DOKA").font(.system(size: 22, weight: .black, design: .rounded)).tracking(3)
            Spacer()
            Menu {
                ForEach(CameraFlashMode.allCases) { mode in
                    Button(mode.label, systemImage: mode.symbol) { camera.setFlashMode(mode) }
                }
            } label: { Image(systemName: camera.flashMode.symbol).frame(width: 40, height: 40) }
            .disabled(!camera.isFlashAvailable).accessibilityLabel(camera.flashMode.label)
            Menu {
                ForEach(PhotoRatio.allCases) { ratio in
                    Button(ratio.rawValue) { model.settings.ratio = ratio }
                }
            } label: { Text(model.settings.ratio.rawValue).font(.system(.subheadline, design: .monospaced)).frame(width: 44, height: 40) }
            Button { showSettings = true } label: { Image(systemName: "gearshape").frame(width: 40, height: 40) }
                .accessibilityLabel("设置")
        }.foregroundStyle(.white)
    }

    private var viewfinder: some View {
        GeometryReader { geometry in
            let ratio = model.settings.ratio.value
            let width = min(geometry.size.width, geometry.size.height * ratio)
            let height = width / ratio
            ZStack {
                Color.black
                if let image = model.preview, camera.isRunning {
                    Image(uiImage: image).resizable().scaledToFill()
                    if model.gridEnabled { ThirdsGrid().stroke(.white.opacity(0.3), lineWidth: 0.5) }
                    if model.levelEnabled { LevelGuide() }
                    CompositionOverlay(composition: model.composition)
                    if let point = focusLocation {
                        RoundedRectangle(cornerRadius: 5).stroke(accent, lineWidth: 1.5)
                            .frame(width: 54, height: 54).position(x: point.x * width, y: point.y * height)
                    }
                } else {
                    cameraPlaceholder.padding(24)
                }
            }
            .frame(width: width, height: height).clipped()
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard camera.isRunning, width > 0, height > 0 else { return }
                let point = CGPoint(x: value.location.x / width, y: value.location.y / height)
                model.focus(at: point)
                focusLocation = point
                focusTask?.cancel()
                focusTask = Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    focusLocation = nil
                }
            })
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    @ViewBuilder private var cameraPlaceholder: some View {
        VStack(spacing: 14) {
            if camera.state == .configuring || camera.state == .requestingPermission || camera.state == .idle || camera.state == .ready {
                ProgressView()
                Text("正在准备相机").font(.subheadline)
            } else {
                Image(systemName: "camera").font(.largeTitle)
                Text(camera.errorMessage ?? "相机暂不可用").font(.subheadline).multilineTextAlignment(.center)
                if camera.state == .denied {
                    Button("打开系统设置") { openSettings() }
                } else if camera.state != .unavailable {
                    Button("重新连接") { camera.start() }
                }
                Text("也可以从下方导入照片").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 20) {
            ForEach([CGFloat(1), 2, 3], id: \.self) { zoom in
                if camera.zoomRange.contains(zoom) {
                    Button { camera.setZoom(zoom) } label: {
                        Text("\(Int(zoom))×").font(.system(.caption, design: .rounded, weight: .semibold))
                            .frame(width: 40, height: 34)
                            .foregroundStyle(abs(camera.zoomFactor - zoom) < 0.05 ? accent : .white)
                            .background(.white.opacity(0.08), in: Capsule())
                    }.accessibilityLabel("\(Int(zoom)) 倍变焦")
                }
            }
        }.disabled(!camera.isRunning)
    }

    private var captureControls: some View {
        HStack {
            PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle").font(.title2).frame(width: 48, height: 48)
            }.accessibilityLabel("导入照片").disabled(model.isProcessing || model.isSaving)
            Button { showLatest = true } label: {
                Group {
                    if let photo = model.latestPhoto { Image(uiImage: photo).resizable().scaledToFill() }
                    else { Color.clear }
                }.frame(width: 34, height: 42).clipShape(RoundedRectangle(cornerRadius: 6))
            }.disabled(model.latestPhoto == nil).accessibilityLabel("最近照片")
            Spacer(minLength: 8)
            Button { model.capture() } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 3).frame(width: 74, height: 74)
                    Circle().fill(.white).frame(width: 62, height: 62)
                    if model.isProcessing || model.isSaving { ProgressView().tint(.black) }
                }
            }.disabled(!camera.isRunning || camera.isCapturing || model.isProcessing || model.isSaving)
                .accessibilityLabel("拍摄并保存照片")
            Spacer(minLength: 8)
            Button { showAdjustments = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title2).frame(width: 44, height: 48)
            }.accessibilityLabel("影像调节")
            Button { camera.switchCamera() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2).frame(width: 44, height: 48)
            }.disabled(!camera.isRunning || camera.isCapturing || model.isProcessing)
                .accessibilityLabel("切换前后摄像头")
        }.foregroundStyle(.white).padding(.vertical, 5)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("取景辅助") {
                    Toggle("九宫格", isOn: $model.gridEnabled)
                    Toggle("水平仪", isOn: $model.levelEnabled)
                }
                Section("保存") {
                    Text("拍摄的照片会应用当前滤镜和裁切比例，保存到系统照片。")
                    Text("导入照片的调整会保存为新照片。")
                }
                Section("关于") { Text("Doka iOS · 0.1.0").foregroundStyle(.secondary) }
                Section("AI 构图账号") {
                    Button("退出 Doka 登录") { model.composition.logout(); showSettings = false }
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                path.move(to: CGPoint(x: rect.width * fraction, y: 0))
                path.addLine(to: CGPoint(x: rect.width * fraction, y: rect.height))
                path.move(to: CGPoint(x: 0, y: rect.height * fraction))
                path.addLine(to: CGPoint(x: rect.width, y: rect.height * fraction))
            }
        }
    }
}
