// 这个文件存在的唯一目的是让 SwiftPM 把 JiJiProtos 认作合法 target。
//
// 背景：本 target 目录里只有 .proto 和生成配置。若一个 target 里没有任何
// Swift 源文件，SwiftPM 会认为它没有 sources（构建时警告
// "Source files for target JiJiProtos should be located under ..."），
// 于是 GRPCProtobufGenerator 插件根本不会被调用 —— 而且**不报错**，
// 只是静默地什么都不生成。踩过一次，别删这个文件。
//
// 真正的内容由插件生成（*_pb.swift / *.grpc.swift）。
enum JiJiProtosTarget {}
