# Doka iOS 移植工程

**状态（2026-10-23）：本地相机与 AI 构图客户端链路已写入源码，尚未使用 Xcode 编译、登录真实账号联调或在 iPhone 上运行。未生成 IPA，未上传 GitHub。**

项目位于 `G:\Doka-iOS`。输入为用户提供的 Doka Android 1.3.19（versionCode 53）APK。APK SHA-256：`5d076292c2bad22259661bac7f1502142001e0bebca60830743ee915d943d0a1`。

## 当前实现范围

- 原生 SwiftUI / AVFoundation 相机：权限请求、前后切换、闪光灯、点按对焦、曝光补偿、1–5×设备支持范围内变焦。
- 24 个原版 LUT，按原版显示顺序排列；同一套 Core Image 管线用于实时预览、拍照和导入照片。
- 原版调色盘的明暗、色彩公式；3:4、1:1、9:16 居中裁切。
- 九宫格与重力水平仪。
- 系统照片选择器、照片调色、保存新照片；拍照自动保存，可在最近照片中重试保存。
- 前后台生命周期、相机中断恢复、异步处理与背压、保存失败提示。
- 无签名 iPhoneOS / arm64 构建、IPA 封装和产物验证脚本。
- AI 构图入口：正常短信登录、Keychain 凭证、服务端权益查询、当前未加滤镜画面的提交和结果解析。
- 推荐画面预览、构图说明、推荐滤镜应用、目标变焦展示；Vision 跟踪目标区域及移动方向提示。
- 请求取消和迟到结果丢弃、跟踪丢失清框、切换镜头/比例/前后台清理旧结果。

以上是已写入源码的功能，不代表已通过 Apple SDK 编译或真机验收。此版固定竖屏，预览限制为约 15 fps / 1080 长边，相机静态照片优先选择 1250 万像素以内支持的尺寸。原版 SDK/机型的色彩和 ISP 行为不同，不能仅凭 LUT 数学测试声称跨设备逐像素一致。导出为 JPEG，不承诺保留原始 EXIF、定位、HDR 或透明通道。导入时裁切为所选比例，原照片保留。

## 尚未实现的原版功能

**AI 尚未完成真实联调。** 原版会把图像提交到云端 `ai_camera/v2`，由后端返回构图区域和滤镜推荐。当前新增的是该协议的 iOS 客户端，使用用户正常登录产生的凭证；APK 中没有服务端模型。首次实测需要可用的原版账号及构图权益，并确认原服务接受此 iOS 移植客户端。原服务的版本、设备规则或接口变化仍可能导致请求失败。

当前 Vision 区域跟踪是 iOS 上的新实现，不等于原版 OpenCV ORB + 陀螺仪路线；遮挡、快速移动或网络等待期间大幅改变画面仍可能失败。未实现原版仅返回模板 URL 时的下载回退、多景别构图和偏好推荐。完整迁移还缺原版跟踪路线、Live Photo/视频、去噪、水印/边框、图库、完整会员购买和交互视觉还原。详细证据见 [逆向分析](docs/reverse-engineering.md)，本轮实现边界见 [AI 构图联调记录](docs/ai-composition.md)。

## AI 构图使用流程（待真机验证）

1. 点击「AI 构图」，用自己的 Doka 手机号和验证码登录。验证码由用户点「获取验证码」时发送；无需将凭据放进源码或发给开发者。
2. 再次点击「AI 构图」，确认把当前画面发送到 Doka 服务。客户端先查询账号权益，无会员或剩余次数时不上传图像。
3. 保持手机稳定。成功返回后显示构图引导；点信息按钮查看推荐画面、说明、目标倍率和滤镜。
4. 目标跟踪丢失时重新分析；重新分析可能消耗次数。取消只会停止客户端等待，已经发给服务器的请求不保证撤销扣次。

没有内置凭据，没有用本地规则伪造服务器的 AI 分析结果，也没有本地解锁会员权益。

## macOS 构建未签名 IPA

需要完整 Xcode（含 iOS SDK）、Python 3 和 XcodeGen。当前 Windows 环境不能执行这个构建。

```bash
brew install xcodegen
bash scripts/build-unsigned-ipa.sh
```

脚本会生成 `Doka.xcodeproj`，编译真实设备 arm64 应用，验证 Mach-O 平台、Info.plist 和 24 个 LUT 的哈希，再打包：

```text
artifacts/Doka-unsigned.ipa
artifacts/Doka-unsigned.ipa.sha256
artifacts/Doka-unsigned.verification.json
```

未签名 IPA 需由用户通过自己的签名工具签名后安装。脚本的结构检查不等同于安装或真机测试。生成工程后也可以在 Xcode 打开、选择自己的开发团队后部署真机。`.github/workflows/build-unsigned-ios.yml` 仅为后续手动构建准备，尚未发布或运行。

## 本地验证与复现

Python 依赖：Pillow。资源已经转换并包含在工程内，普通 iOS 构建无需原 APK 或 Pillow。

```powershell
$env:DOKA_SOURCE_APK = '你的原APK完整路径'
python -m unittest discover -s tests -v
```

不提供 `DOKA_SOURCE_APK` 时跳过真实 APK 对照测试，仍运行合成数据测试。重新从同一 APK 生成 LUT：

```powershell
python scripts/extract-luts.py '你的原APK完整路径'
```

源 PNG 与转换数据的 SHA-256 见 [资源清单](docs/lut-manifest.json)。测试结果与真机待验收项见 [验证记录](docs/validation.md)。

AI 协议的 XCTest 在 `tests/ios/`。Mac 上运行 `bash scripts/test-ios.sh`；这些测试检查 Swift 响应解码、几何数据、权益和 multipart，不登录真实账号或调用网络。本机仅做静态检查，尚未运行 XCTest。

`work/` 保存静态反编译和工具等本地材料，不进入源码交付包或 Git。工程不打包 Android 原生库、反编译 Java、账号凭据或原 APK。

## 实现参考

- [Apple AVCam](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app)：相机会话与照片捕获。
- [Apple CIColorCube](https://developer.apple.com/documentation/coreimage/cicolorcube)：三维颜色查找表。
- [XcodeGen ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)：工程生成配置。
- [Apple Vision 坐标说明](https://developer.apple.com/documentation/vision/vndetectedobjectobservation/boundingbox)：归一化坐标以左下为原点，与界面/服务的左上坐标转换。
