# JiJiDownMac

**唧唧（JiJiDown）2 的 macOS 原生客户端 —— 非官方，第三方实现。**

> ⚠️ **本项目与唧唧官方无任何隶属关系，未获其背书。**
> 「唧唧 / JiJiDown」及其核心二进制的版权归**唧唧作者**所有。本仓库不包含、
> 不分发其二进制，构建时从官方地址获取。详见 [NOTICE.md](NOTICE.md)。

---

## 这是什么

唧唧 2 的官方形态是「**核心二进制 + WebUI**」。但官方 WebUI 地址并不公开 ——
文档写明需要加入体验群才能拿到。也就是说，走官方路径你下载到的只是一个**没有
界面的守护进程**。

这个项目补上那个缺失的界面：一个自包含的 macOS App，**自己托管核心进程**
（下载、校验、写配置、启停、崩溃重启、日志捕获），用 SwiftUI 提供完整 UI。
双击即用，全程不碰终端。

### 为什么不算「重新实现」

官方核心在 `external-controller` 上暴露**原生 gRPC** 接口，其文档明确把
Swift 列为受支持语言，`.proto` 里还带着 `option csharp_namespace` ——
厂商本就在做多语言 SDK。**第三方写原生客户端是其设计之内的事**，不需要逆向。

所有下载能力、账号授权、会员限制**都由官方核心提供**，本项目不做任何绕过：
核心说不行就是不行，客户端只负责把话说清楚。

## 功能

| 模块 | 能做什么 |
|---|---|
| **账号** | 扫码登录（二维码内嵌在窗口里，带倒计时与刷新）、Cookie 导入 |
| **解析** | 粘贴链接或 BV 号 → 标题 / 封面 / UP主 / 分P |
| **下载** | 清晰度（8K / **杜比视界** / HDR / 4K / 1080P60 / … / 360P）、编码（AVC / HEVC / AV1）、音质（Hi-Res / 192K / 132K / 64K） |
| **任务** | 队列与进度、速度与 ETA、暂停 / 继续 / 删除 |
| **核心** | 运行状态、实时日志、崩溃自动重启 |

**杜比视界（清晰度 id `126`）需要配合 HEVC 编码**，界面上有提示。

## 构建

需要 macOS 15+ 与 Swift 6.1+。**不需要 Xcode** —— 只需 Command Line Tools，
`.app` 由脚本手工组装（本机没有 `xcodebuild`/`actool`，图标走不了 Asset Catalog）。

```bash
brew install protobuf          # 代码生成要 protoc

./Scripts/fetch-core.sh        # 从唧唧官方地址拉核心二进制并校验 sha256

swift build                    # 首次会拉 ~20 个 SwiftNIO 系依赖，比较久
./Scripts/bundle.sh            # 组装 dist/JiJiDown.app

open dist/JiJiDown.app
```

网络受限时给 SwiftPM 带上代理：

```bash
HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890 swift build
```

### 开发工具

`JiJiProbe` 是协议层探针（不进 App bundle），用来在没有 UI 的情况下验证核心行为：

```bash
swift build
.build/debug/JiJiProbe                              # 连通性与授权门探针
.build/debug/JiJiProbe status                       # 登录状态
.build/debug/JiJiProbe dl BV1xxxxxxxxx "" 126 hevc  # 下载（126=杜比视界）
.build/debug/JiJiProbe dl BV1xxxxxxxxx              # 默认 1080P / HEVC
```

清晰度与编码按位置给：`dl <BV号> [文件名] [清晰度id] [编码]`。
文件名目前传了没用（见下方「已知限制」），保持原样是为了等核心修好。

## 已知限制

都是**核心本身的行为**，客户端只能如实呈现或绕开，无法修复：

- **`AllQuality` / TV / APP 接口是唧唧会员功能。** 非会员拿不到「可用清晰度枚举」，
  只能按 B 站标准 id 直接选；选了该视频没有的档位，核心会报错，换个档位即可。
  客户端因此提供完整档位下拉，而不是等核心枚举。
- **`save_filename` 参数被核心无视（r339）。** 实测传 `"墨脱-1080P"` 进去，
  产出照样是下面那个名字。
- **核心生成的文件名标题是空的。** 命名模板是 `%s (%s, %s, %s, %s)`，第一个
  `%s` 是标题，而 r339 不填这个字段 → 所有同档位下载都叫
  ` (高清 1080P, HEVC, 极高音质, WEB).mp4`，**并行时会互相覆盖**。

  这是本项目里最需要小心的一处，客户端做了两件事兜住它：
  1. `OutputNaming`：任务完成后按标题重命名，且**绝不覆盖已有文件**
     （重名自动加 `(2)` 序号）。
  2. 生成的配置里 `max-task: 1`：串行下载，保证第二个任务落盘时那个文件名
     已经被腾空。代价是不能并行下载 —— 但比静默丢文件强。

  另外任务状态也有个坑：核心下完后状态**停在 `TASK_GENMUSIC(5)`，不会翻到
  `TASK_COMPLETE(6)`**。所以完成判据是 `completeTime != 0`（`isFinished`），
  不是看枚举。
- **`video_codec = UNKNOWN(0)` 会让核心 panic**（`index out of range [0] with length 0`，
  在 `JDMTask.NewSession`）。协议层已硬性拦截，默认编码是 HEVC。
- **控制器端口零鉴权。** 任何能连上 4000 端口的进程都能读任务列表、导入 Cookie、
  删本地文件。客户端只连 `127.0.0.1`，绝不监听 `0.0.0.0`。
- `125`（HDR）与 `30250`（全景声）是否可用**取决于视频本身**，不是所有视频都有。

## 目录结构

```
Sources/
├── JiJiProtos/     .proto 定义 + grpc-swift 代码生成配置
├── JiJiKit/        协议层（CoreClient）+ 核心托管（CoreManager）+ 清晰度枚举
├── JiJiDown/       SwiftUI 应用
└── JiJiProbe/      协议探针（开发工具）
Scripts/
├── fetch-core.sh   从官方地址取核心二进制并校验
├── bundle.sh       手工组装 .app
└── smoke-core.sh   核心二进制冒烟测试
```

### 两个容易踩的坑（都已处理，改代码时别踩回去）

1. **代码生成插件会静默失败。** `GRPCProtobufGenerator` 靠一个固定文件名的
   `grpc-swift-proto-generator-config.json` 驱动；文件缺失或名字写错，它
   **什么都不做也不报错**。所以 `Sources/JiJiProtos/` 里放了个
   `ProtosTarget.swift` 占位文件 —— 没有它，SwiftPM 不认为这是个有效 target，
   插件根本不会跑。
2. **`google/protobuf/empty.proto` 必须放在 target 目录之外**（见
   `Protos-External/`）。放进去的话插件会连它也生成一份 Swift 代码，与
   `SwiftProtobuf` 模块自带的 `Google_Protobuf_Empty` 重复定义，编译失败。

## 许可证

本项目源码采用 [MIT](LICENSE)。`.proto` 接口定义与 `JiJiDownCore` 二进制
**不受** MIT 覆盖，版权归各自作者 —— 详见 [NOTICE.md](NOTICE.md)。

仅供学习与个人使用。使用者需自行承担遵守 B 站服务条款、著作权法与唧唧用户
协议的责任。
