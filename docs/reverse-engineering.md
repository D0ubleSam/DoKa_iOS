# Doka Android APK 逆向调查

分析日期：2026-10-22。仅进行 ZIP、资源、DEX 反编译和静态阅读；没有运行 APK，也没有请求原服务后端。

## 结论与边界

本包是 Kotlin/Java + Android 原生 Camera2/厂商适配 + OpenGL ES/GPUImage 的相机应用，不是可直接换壳的网页应用。可恢复的 LUT 和色彩公式足以实现 iOS 本地图像处理；相机、相册、传感器和界面应使用 iOS 原生框架重建。

最核心的“AI 构图”和“AI 滤镜推荐”是云端能力：客户端上传拍摄画面到 `ai_camera/v2`，服务端返回推荐构图、焦距和滤镜。APK 中没有与该云端等价的离线构图模型或服务端代码。因此，离线主体检测/三分法引导可以作为新实现，但不能称为恢复了原版 AI 或具有完全一致的结果。

本报告不等于 iOS 功能已实现或已验证。尤其是真机相机、滤镜色彩、裁切和旋转方向、交互及性能仍需要 iPhone 验证。

## 输入与工具

- APK：`C:/Users/D0ubleSam/Desktop/Temp/com.ydgn.doka.apk`
- SHA-256：`5d076292c2bad22259661bac7f1502142001e0bebca60830743ee915d943d0a1`
- 文件大小：98,578,635 字节。
- 包名：`com.ydgn.doka`。
- 版本：`1.3.19`，versionCode `53`（解码后的 AndroidManifest.xml 第 3–4 行）。
- 架构：`arm64-v8a`，3 个 DEX，24 张 LUT。
- 工具：JADX 1.5.6；反编译结果位于 `work/decompiled/`。JADX 输出含混淆名称和反编译失败片段，不应把这些 Java 文本当作可重建的 Android 源工程。

## 功能与迁移矩阵

| 原版功能 | APK 中的证据 | iOS 路径 / 当前可恢复程度 |
|---|---|---|
| 后置/前置拍照、变焦、闪光灯、触屏拍摄 | `camera/base`、`camera/control`、`camera/camera2` 和字符串资源 | AVFoundation 重写；厂商 Camera2 参数不可直接迁移 |
| 画幅与裁切 | `camera/base/consts/RatioType.java`、`photoedit/DokaCropActivity.java` | 按照片显示方向裁切，真机验证 |
| 24 个胶片 LUT 与强度 | `F1/c.java`、`camera/filter/LutFilterProcessor.java` | 可精确还原 LUT 数据布局与混合公式 |
| Doka 调色盘（色调、色彩、强度） | `camera/GLPreviewRenderer.java`、`camera/palette` | 可还原公式，预览与成片一致性要验证 |
| 辅助线、水平仪 | `view/NineGridView.java`、`view/LevelOverlayView.java` | SwiftUI/CoreMotion 可重建 |
| AI 构图与多景别构图 | `camera/composition/AiCompositionController.java`、`http/ApiService.java` | 云端模型不在 APK；依赖正式可用的服务接口或另做离线算法 |
| 实时构图圆环/画面跟踪 | `CompositionMatcher.java`、`composition/geo` | 可阅读恢复 ORB+姿态几何；若改用 Vision/CoreMotion，行为不等价 |
| 选择拍照主体 | `view/SubjectMarkerOverlayView.java`、对应 camera_subject 字符串 | 长按标记、调整框、取消等交互可重建；识别服务仍独立依赖 |
| AI 推荐滤镜与场景偏好 | `entity/AiCameraFilterModel.java`、AI preference Activities | 本地偏好编辑可恢复；推荐来自服务端 |
| 保存底片、相册浏览 | 相机后处理、gallery 类及 `camera_option_save_raw` | PhotoKit 重写；“底片”需区分未加滤镜 JPEG 与 RAW/DNG，不能仅凭文案承诺 RAW |
| 时间/机型水印、边框 | WatermarkSettings/PhotoBorderSettings Activities、资源字符串 | 原生图片合成，资源与排版单独恢复 |
| 实况照片 | `camera/livephoto/LivePhotoVideoFilterProcessor.java` | iOS Live Photo 必须重建成片配对及元数据；非普通 JPEG+任意视频 |
| 登录、会员、支付、兑换码、远端配置 | `http/ApiService.java`、相关 entity/Activities | 依赖服务端和对应 iOS 支付/身份接入，不能用本地开关等价替代 |

## 实施优先级

- P0 / 第一阶段：原生相机拍照、前后镜头、变焦/闪光灯、24 LUT、强度和调色盘、照片导入/保存、基础网格与水平仪。只报告实际实现及验证程度。
- P1 / 后续本地能力：画幅/裁切细节、底片保存、水印与边框、主体框交互、偏好持久化和真机画质/性能回归。
- P2 / 独立扩展：Live Photo、原版复杂跟踪策略与本地构图替代算法，需单独实现和验证。
- P3 / 依赖外部服务：原版 AI 构图、AI 滤镜推荐、账号、会员、支付、远程配置。需要合法可用的服务接入和 iOS 端配置，单靠此 APK 不能完成原后端复制。

第一阶段不能描述为“完整迁移原版”或“AI 已恢复”。本次报告只覆盖静态调查；实际已完成项以项目 README 和验证记录为准。Android 反编译 Java、第三方 SDK 与工具都保留在 `work/` 分析区，不作为 iOS 工程源码发布。

## LUT 数据与处理顺序

全部 LUT 都是 512×512 PNG，内含 8×8 个 64×64 蓝色切片；RGB 或 RGBA。静态图使用 GPUImageLookupFilter，预览使用 GLPreviewRenderer 内嵌 shader。`assets/shaders/fragment_shader_lut_es2.glsl` 是 AndroidX Media3 的纵向 3D LUT 格式，不是这些 PNG 的直接数据布局。

整数输入索引 r/g/b 均在 0…63 时，PNG 从左上开始的像素坐标是：

```text
x = (b % 8) * 64 + r
y = (b / 8) * 64 + g
cube[r][g][b] = PNG[x, y]
```

这一方向在 `LivePhotoVideoFilterProcessor.toMedia3LutCube`（约第 334 行）有独立的 CPU `Bitmap.getPixel` 转换验证，不需要人为上下翻转 LUT。

连续颜色 RGB ∈ [0,1] 时：R/G 对应切片内双线性采样；B×63 对应相邻蓝切片插值；最后 `mix(sourceRGB, lutRGB, intensity)`。保留输入 alpha。所有预设初始 intensity = 1.0（枚举字段 100，再除以 100），用户可调 0…1。不得把文件顺序当成 RGB cube 的连续内存布局；Core Image 的 cube 数据必须按其索引规则重新排列。

预览处理顺序：输入颜色 → LUT → LUT 强度混合 → 调色盘。调色盘公式摘录为数学描述（tone/chroma ∈ [-1,1]，amount ∈ [0,1]）：

```text
original = color
scaled = color * 2^(tone * 0.18)
luma = dot(scaled, [0.299, 0.587, 0.114])
contrast = max(0.68, 1 - tone * 0.16)
graded = (scaled - 0.5) * contrast + 0.5
saturation = 1 + chroma * 0.42
graded = luma + (graded - luma) * saturation
output = clamp(mix(original, graded, amount), 0, 1)
```

注意 luma 在 contrast 之前计算。通用 CIColorControls 的 saturation/contrast 顺序不必然等价；若追求原算法，要使用同一数学顺序。工作色域/伽马也会影响最终一致性，需在 iOS 上比对。

## 24 个滤镜

分组编码为 APK 枚举原值，不推断为付费层级。

| 序号 | 显示名称 | APK 资源 | 分组 |
|---|---|---|---|
| 1 | F Classic Chrome | `luts/lut_f_classic_chrome.png` | 0 |
| 2 | F PROVIA | `luts/lut_f_provia.png` | 0 |
| 3 | F Velvia | `luts/lut_f_velvia.png` | 0 |
| 4 | F CC | `luts/lut_f_cc.png` | 0 |
| 5 | F Classic Neg | `luts/lut_f_classic_neg.png` | 0 |
| 6 | F CN | `luts/lut_f_cn.png` | 0 |
| 7 | F C200 | `luts/lut_f_c200.png` | 0 |
| 8 | F 160C | `luts/lut_f_160c.png` | 0 |
| 9 | F Pro Neg | `luts/lut_f_pro_neg.png` | 0 |
| 10 | F 400H | `luts/lut_f_400h.png` | 0 |
| 11 | F S100 | `luts/lut_f_s100.png` | 0 |
| 12 | F S400 | `luts/lut_f_s400.png` | 0 |
| 13 | Portra 160 | `luts/lut_k_portra_160.png` | 1 |
| 14 | Gold 200 | `luts/lut_k_gold_200.png` | 1 |
| 15 | Portra 400 | `luts/lut_k_portra_400.png` | 1 |
| 16 | Vista 800 | `luts/lut_agfa_vista_800.png` | 2 |
| 17 | AP 100 | `luts/lut_agfa_ap_100.png` | 2 |
| 18 | Doka S100 | `luts/lut_doka_s100.png` | 3 |
| 19 | Doka S50 | `luts/lut_doka_s50.png` | 3 |
| 20 | Doka S160 | `luts/lut_doka_s160.png` | 3 |
| 21 | Doka S200 | `luts/lut_doka_s200.png` | 3 |
| 22 | Doka S400 | `luts/lut_doka_s400.png` | 3 |
| 23 | Doka X400 | `luts/lut_doka_x400.png` | 4 |
| 24 | Doka X100 | `luts/lut_doka_x100.png` | 4 |

## AI 构图数据流

1. 取得分析帧或拍照 fallback JPEG，同时保存旋转矩阵、焦距/变焦、传感器几何、图像尺寸与屏幕方向快照。
2. 使用 multipart POST `ai_camera/v2` 上传 JPEG。参数包含 `shoot_type`、`direction`、`compose_times`、`scan_focal_length`、`ai_filter`、时间戳、`comp_scene`、`recommend_mode`、`ai_filter_preferences`、语言/region/distribution。
3. CameraData 返回 `ExifFocalLength`、`BodyRange`、`PredictSubAreaPicURL`、`PicWithPredictAreaLine`、`LeftTopCrd`、`RightDownCrd`、`SubAreaRectNorm`、`ComposeReason`、`AiCameraFilter(s)` 等。它是服务端产生的目标，不是客户端在 DEX 中计算出的最优构图。
4. 客户端下载/设置构图模板，提取 OpenCV ORB 特征，KNN 两近邻匹配，距离比阈值 0.9；至少 6 个初始匹配、至少 4 点进入 `findHomography`，使用 RANSAC 及 4.0 像素阈值。
5. 将模板中心与尺寸透视映射到预览，绘制对准提示。新几何路线将构图点转为世界方向，随当前旋转和焦距重新投影；每 6 帧做一次 ORB 校验，并有 2 像素静止死区和小幅平滑修正。
6. AR 样式引导基于图像匹配与传感器几何。没有证据表明这个 APK 内含能够独立完成原 AI 决策的 3D 场景模型。

接口地址与请求头在 `I1/f.java`、`I1/b.java` 可见；用户认证由 bearer token 处理，并携带版本、地区、渠道及设备信息。本次没有复制凭据、没有调用服务、没有验证服务端接受非官方 iOS 客户端。Android native security 库含签名/运行环境检查，这些 Android 二进制不能直接链接进 iOS，亦不应把伪造通过检查当成移植完成条件。

## 权限

Manifest 包含：相机、录音、精确/粗略定位、网络、网络/Wi-Fi 状态、电话状态、震动、安装包、计费、生物识别、唤醒锁、广告标识/归因和若干 SDK 权限。权限声明不意味着核心拍照必须全部请求。

iOS 最小离线拍照版只需相机和保存照片的权限；相册导入优先 PhotosPicker；若真正实现带声音的 Live Photo 才加麦克风；定位只在明确实现照片位置功能时请求。Android 安装包、电话状态、Google Billing 等权限没有逐项移植意义。

## 本次静态验证与剩余验证

已验证：包版本/结构，24 张资源的尺寸和可解码性，滤镜列表/默认强度，LUT 方向的 shader+CPU 双证据，调色盘公式，云端构图接口与客户端跟踪链路。

未验证：原应用运行界面、后端在线响应、用户账号/付费能力、原版与 iOS 的像素对比、iOS 编译、相机真机兼容性、未签名 IPA 的侧载安装。Windows 静态分析与资源转换不等于已完成这些验证。
