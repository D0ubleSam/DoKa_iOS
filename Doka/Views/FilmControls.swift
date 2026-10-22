import SwiftUI

struct FilmStrip: View {
    @Binding var settings: RenderSettings
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FilmFilter.all) { film in
                    Button { settings.filterID = film.id } label: {
                        VStack(spacing: 5) {
                            Text(film.family.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.5)
                                .foregroundStyle(.secondary)
                            Text(film.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        }.padding(.horizontal, 13).frame(height: 52)
                            .background(settings.filterID == film.id ? Color.white.opacity(0.16) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.filterID == film.id ? Color.accentColor : .clear, lineWidth: 1))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(settings.filterID == film.id ? .isSelected : [])
                }
            }.padding(.vertical, 2)
        }.frame(height: 58)
    }
}

struct AdjustmentSheet: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("胶片") { RenderSliders(settings: $model.settings) }
                Section("相机") {
                    LabeledContent("曝光补偿", value: String(format: "%+.1f EV", camera.exposureBias))
                    Slider(value: Binding(get: { camera.exposureBias }, set: { camera.setExposureBias($0) }), in: camera.exposureRange)
                        .accessibilityLabel("曝光补偿")
                    LabeledContent("变焦", value: String(format: "%.1f×", camera.zoomFactor))
                    Slider(value: Binding(get: { camera.zoomFactor }, set: { camera.setZoom($0) }), in: camera.zoomRange)
                        .accessibilityLabel("变焦")
                }.disabled(!camera.isRunning)
                Button("重置影像调整") {
                    model.settings.intensity = 1; model.settings.tone = 0; model.settings.chroma = 0
                    model.settings.paletteIntensity = 1
                    camera.setExposureBias(0)
                }
            }.navigationTitle("影像调节").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct RenderSliders: View {
    @Binding var settings: RenderSettings
    var body: some View {
        LabeledContent("滤镜强度", value: "\(Int(settings.intensity * 100))%")
        Slider(value: $settings.intensity, in: 0...1).accessibilityLabel("滤镜强度")
            .disabled(settings.filterID == FilmFilter.original.id)
        LabeledContent("明暗", value: String(format: "%+.0f", settings.tone * 100))
        Slider(value: $settings.tone, in: -1...1).accessibilityLabel("明暗")
        LabeledContent("色彩", value: String(format: "%+.0f", settings.chroma * 100))
        Slider(value: $settings.chroma, in: -1...1).accessibilityLabel("色彩")
        LabeledContent("调色强度", value: "\(Int(settings.paletteIntensity * 100))%")
        Slider(value: $settings.paletteIntensity, in: 0...1).accessibilityLabel("调色强度")
    }
}

struct PhotoEditor: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Group {
                    if let image = model.editedPreview { Image(uiImage: image).resizable().scaledToFit() }
                    else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Picker("裁切比例", selection: $model.settings.ratio) {
                    ForEach(PhotoRatio.allCases) { ratio in Text(ratio.rawValue).tag(ratio) }
                }.pickerStyle(.segmented)
                FilmStrip(settings: $model.settings)
                VStack(spacing: 4) { RenderSliders(settings: $model.settings) }.font(.caption)
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                Button { model.saveEditedPhoto() } label: {
                    HStack {
                        if model.isSaving { ProgressView() }
                        Text(model.isSaving ? "正在保存" : "保存新照片")
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).disabled(model.isSaving || model.editedPreview == nil)
            }.padding(16).background(Color(white: 0.045))
                .navigationTitle("照片调色").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(model.isSaving) } }
                .alert("未能保存", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button("知道了", role: .cancel) { model.errorMessage = nil }
                } message: { Text(model.errorMessage ?? "请重试。") }
        }
    }
}
