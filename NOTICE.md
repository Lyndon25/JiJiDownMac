# 声明与第三方归属

## 许可证的覆盖范围

仓库根目录的 [LICENSE](LICENSE) 是**未经改动的 MIT 正文**（这样 GitHub 才认得出
它是 MIT）。但 MIT **只覆盖本项目作者编写的源代码**，不覆盖：

1. **JiJiDownCore** —— 唧唧官方提供的闭源预编译二进制。版权归唧唧作者所有，
   本仓库不分发它，仅由 `Scripts/fetch-core.sh` 从官方地址获取。
2. **`Sources/JiJiProtos/` 与 `Protos-External/` 下的 `.proto` 接口定义** ——
   来自唧唧官方 SDK，为互操作性而收录，版权归原作者。
3. **第三方 Swift 依赖**（grpc-swift、swift-protobuf、SwiftNIO 等）——
   各自遵循其自身许可证，见下方表格。

## 本项目与唧唧（JiJiDown）的关系

**本项目是非官方第三方客户端，与唧唧官方没有任何隶属或合作关系。**

- **唧唧 / JiJiDown** 是 B 站视频下载工具，其名称、图标、`JiJiDownCore`
  二进制及相关资源的版权与商标归**唧唧作者**所有。
- 本仓库**不包含也不分发** `JiJiDownCore` 二进制。构建时由
  `Scripts/fetch-core.sh` 从**唧唧官方发布地址**下载，并用官方公布的
  SHA-256 清单校验完整性。
- 本项目作者与唧唧官方无关联，未获其背书。使用唧唧核心仍需遵守唧唧自己的
  用户协议与授权规则（包括其会员功能限制）。

## 为什么会有这个项目

唧唧 2 的官方形态是「核心二进制 + WebUI」，但 WebUI 地址不公开（官方文档：
需加入体验群获取）。官方核心本身在 `external-controller` 上暴露了原生
gRPC 接口，其文档明确列出 Swift 为受支持语言，且 `.proto` 定义中带有
`option go_package` / `option csharp_namespace` —— 说明厂商本就在做多语言
SDK，第三方编写原生客户端是其设计之内的事。

因此本项目的定位是：**补上一个官方没公开提供的 macOS 原生界面**，而不是
替代或重新实现唧唧核心。所有下载能力、授权校验、会员限制都由官方核心提供，
本项目不做任何绕过。

## 接口定义（`.proto`）来源

`Sources/JiJiProtos/` 与 `Protos-External/` 下的 `.proto` 文件来自
**唧唧官方 SDK 的公开定义**（经第三方仓库转载获得），版权归原作者。

这些文件在此**仅为互操作性而收录**，不受本仓库 MIT 许可证覆盖。

其中 `Sources/JiJiProtos/bvideo.proto` 有两处**基于实测的修正**，
原因已写在文件内注释里 —— 上游公开定义与 r339 核心的实际线上格式不一致，
照原样编译会导致解析失败。改动是兼容性修复，不是重新定义接口。

## 第三方依赖

| 依赖 | 许可证 |
|---|---|
| [grpc-swift](https://github.com/grpc/grpc-swift) | Apache-2.0 |
| [swift-protobuf](https://github.com/apple/swift-protobuf) | Apache-2.0 |
| [SwiftNIO](https://github.com/apple/swift-nio) 及同族包 | Apache-2.0 |
| `Protos-External/google/protobuf/empty.proto` | Google, BSD-3-Clause |

## 免责

本项目仅供学习与个人使用。使用者需自行承担遵守 B 站服务条款、著作权法及
唧唧用户协议的责任。请勿用于下载、传播未经授权的内容。
