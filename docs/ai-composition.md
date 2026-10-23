# AI 构图实现与联调边界

更新：2026-10-23。源码位于 `Doka/Composition/`，界面为 `Doka/Views/CompositionControls.swift`。

## 已写入客户端的流程

`点击 AI → 手机验证码登录 → 用户确认上传 → 查询权益 → 上传当前取景 JPEG → 解析云端结果 → 推荐画面/滤镜 → Vision 区域跟踪 → 方向提示`

- `AIService`：固定 HTTPS 原服务，JSON 登录与 multipart 分析；只跟随同源 HTTPS 重定向；真实标识 iOS 移植版本 0.1.0，不冒充 Android 官方构建。
- `AITokenStore`：仅保存正常登录返回的 bearer token，使用本机 Keychain。注销使在途旧登录失效，防止迟到响应重新登录。
- `AIModels`：业务 `code=0` 为成功，三个原版认证错误码清理失效凭证；其余错误保留服务消息。
- `AIEntitlementPayload`：处理会员和三种历史剩余次数字段，缺失或零次均不开放构图；每次分析前向原服务查询。
- `CompositionModel`：只发送用户当次确认的未滤镜、已裁切、竖向 JPEG（最长边 768、质量 0.85）；请求取消、换镜头/画幅、会话中断或前后台切换后丢弃旧结果。
- `CompositionTracker`：将请求帧中的构图区域交给 Vision，转换左上/左下原点；低置信度、区域越界或帧比例改变时清框并提示重新分析。
- 界面提供构图理由、推荐画面的裁切预览、目标倍率和能匹配到本地资源的滤镜；不会自动使用未识别的滤镜名称。

## 从 APK 确认的协议细节

- 原版入口要求已登录，且有效 VIP 或构图剩余次数大于 0。证据：`work/decompiled/sources/G1/B0.java:1470`。
- `scan_focal_length` 和返回的 `ExifFocalLength` 都是变焦倍率，非毫米。证据：`G1/Y.java:47`、`G1/B0.java:456`、`:3484`。
- 上传图片字段 `file`，类型 `image/jpeg`；`shoot_type=scenery`、`direction=shu`、首次 `compose_times=1`、`ai_filter=on`、毫秒时间戳。
- 中文 `language=ZH`，英文 `EN`；中国源 APK 的 region/distribution 为 china/store。
- 普通短信登录省略 `scene`；phone_num/msg_code/username 对应原始请求字段。
- `SubAreaRectNorm` 为 `{X,Y,W,H}` 或小写，使用本次 JPEG 的左上归一化坐标。当前解析还支持完整像素坐标字段回退，但服务返回的实际像素基准仍需真实响应验证。
- 业务错误 `-20001/-20002/-20004` 为认证失效。没有凭空映射其他错误码。

## 实际执行过的在线检查

此前仅做了两个不含照片、手机号和登录凭据的请求：

1. `OPTIONS /ai_camera/v2` 返回 HTTP 204。
2. 空 multipart `POST /ai_camera/v2` 返回 HTTP 200，业务 code `-10001`，提示缺少 device_model。

这只能证明路径有响应和部分请求校验存在。**没有成功发送验证码、登录、查询账号权益或取得真实 AI 构图结果。** 不把 HTTP 200 当作业务成功，不把此探测当作 iOS 兼容性验证。此后没有重复探测或上传用户照片。

原服务公开 [隐私政策](https://www.yindoka.com/web/android/privacy_policy) 也说明 AI 分析会将临时图像帧发到服务端。该页面说明的是原服务，不代表本移植工程已获官方支持。

## 仍需完成

- Mac 上实际编译、运行 XCTest，修复 Apple SDK 类型或链接问题。
- 用户在 App 中通过正常登录取得自己的账号会话；验证会员/免费次数读取和扣次规则。
- 真机成功得到至少一个 AI 响应，验证矩形、像素尺寸、目标倍率与推荐画面。
- 在静止、缓慢平移、变焦、遮挡、网络超时和后台恢复情形验证跟踪。
- 原版 ORB/姿态跟踪和当前 Vision 跟踪不等价；不能仅凭静态检查声称一致。仅返回模板 URL 的服务响应暂不支持，不会下载任意服务返回 URL 来假装成功。
- 若服务拒绝 iOS 移植客户端，需要可用的服务接入方案；不能从 APK 中补出不存在的服务端模型。
