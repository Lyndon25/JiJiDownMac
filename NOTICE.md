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
  用户协议与授权规则。

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
**唧唧官方 SDK 的公开定义**，取自厂商自己的 GitHub 仓库
[JiJiDown/jithon](https://github.com/JiJiDown/jithon)（唧唧 2.0 的官方 Python 客户端），
版权归原作者。

需要留意的是**这份公开 proto 比实际发布的核心旧**：jithon 最后更新停在 2023-08，
而本机跑的核心是 2026-01 构建的 r339。字段对不上正源于此 —— 修正记录写在
`bvideo.proto` 与 `task.proto` 的注释里。

这些文件在此**仅为互操作性而收录**，不受本仓库 MIT 许可证覆盖。

其中 `Sources/JiJiProtos/bvideo.proto` 与 `Sources/JiJiProtos/task.proto`
有若干处**基于实测的修正**，原因已写在文件内注释里 —— 上游公开定义与 r339 核心
的实际线上格式不一致：前者照原样编译会解析失败或读出空值，后者不报错，只是把
请求参数丢在核心不读的字段上。

改动都是兼容性修复：按实测把字段编号与类型改回核心真正使用的那个，
`SourceType` 枚举是按核心内嵌的描述符补录的。**没有增删任何 RPC。**

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
