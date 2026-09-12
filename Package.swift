// swift-tools-version:6.1
import PackageDescription

// JiJiDown 唧唧 2 的第三方原生 macOS 客户端。
//
// 注意：grpc-swift 2.x 已拆成三个独立包，没有 `GRPC` 伞形 product，
// 也不要和 v1 的 `grpc-swift` 混用。
let package = Package(
  name: "JiJiDownMac",
  platforms: [.macOS(.v15)],  // grpc-swift 2.x 的硬性下限，写低了解析即失败
  products: [
    .library(name: "JiJiKit", targets: ["JiJiKit"])
  ],
  dependencies: [
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.3"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.9.2"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1"),
    // 显式声明：生成的代码用到了 Google_Protobuf_Empty，
    // 需要直接 `import SwiftProtobuf` 才能构造它。
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
  ],
  targets: [
    // 只放 .proto + 生成配置；生成的 Swift 代码会成为本 target 的一部分。
    // 配置文件名必须精确为 grpc-swift-proto-generator-config.json，
    // 否则插件静默不运行（已知陷阱）。
    .target(
      name: "JiJiProtos",
      dependencies: [
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf")
      ],
      plugins: [
        .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
      ]
    ),
    .target(
      name: "JiJiKit",
      dependencies: [
        "JiJiProtos",
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
      ]
    ),
    // 协议探针。`swift run JiJiProbe` 可直接对着跑着的核心验证链路，
    // 不必启动 UI。属于开发工具，不进 App bundle。
    .executableTarget(
      name: "JiJiProbe",
      dependencies: ["JiJiKit"]
    ),
    // 可执行文件名必须是 JiJiDown —— Scripts/bundle.sh 按这个名字找产物。
    .executableTarget(
      name: "JiJiDown",
      dependencies: ["JiJiKit", "JiJiProtos"]
    ),
  ]
)
