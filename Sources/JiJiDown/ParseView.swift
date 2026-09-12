import JiJiKit
import JiJiProtos
import SwiftUI

struct ParseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("粘贴 B 站链接或 BV 号", text: $model.input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.parse() } }

                Button("解析") { Task { await model.parse() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.input.isEmpty || model.isParsing || !model.core.phase.isRunning)
            }

            if model.isParsing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("解析中…").foregroundStyle(.secondary)
                }
            }

            if let error = model.parseError {
                ErrorBox(text: error)
            }

            if let video = model.parsedVideo {
                VideoCard(video: video)
            }

            if let info = model.parsedVideo, !info.block.isEmpty {
                PagePicker(video: info, selection: $model.selectedPage)
            }

            if model.qualities == nil, model.parsedVideo != nil {
                QualityUnavailableNote()
            } else if let qualities = model.qualities {
                QualitySummary(qualities: qualities)
            }

            if let video = model.parsedVideo,
               let page = model.selectedPage ?? video.block.first?.list.first
            {
                DownloadOptions(page: page)
            }

            Spacer()
        }
        .padding(18)
    }
}

// MARK: - 组件

private struct ErrorBox: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct VideoCard: View {
    let video: Jijidown_Core_BvideoInfoReply

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let cover = NSImage(data: video.videoCover) {
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(16 / 10, contentMode: .fill)
                    .frame(width: 168, height: 105)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: 168, height: 105)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(video.displayTitle)
                    .font(.headline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if let up = NSImage(data: video.upFace) {
                        Image(nsImage: up).resizable().frame(width: 18, height: 18).clipShape(.circle)
                    }
                    Text(video.upName).font(.callout).foregroundStyle(.secondary)
                    if !video.sort.isEmpty {
                        Text(video.sort)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }

                if !video.videoDesc.isEmpty {
                    Text(video.videoDesc)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
    }
}

private struct PagePicker: View {
    let video: Jijidown_Core_BvideoInfoReply
    @Binding var selection: Jijidown_Core_BvideoPage?

    var body: some View {
        let pages = video.allPages
        if pages.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("分P（\(pages.count)）").font(.subheadline).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(pages, id: \.pageCid) { page in
                            let active = (selection?.pageCid ?? pages.first?.pageCid) == page.pageCid
                            Button {
                                selection = page
                            } label: {
                                Text("P\(page.pageIndex) \(page.pageTitle)")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(
                                        active ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                               : AnyShapeStyle(.quaternary),
                                        in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct QualitySummary: View {
    let qualities: Jijidown_Core_BvideoAllQualityReply

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("可用清晰度").font(.subheadline).foregroundStyle(.secondary)

            if qualities.video.isEmpty && qualities.audio.isEmpty {
                Text("核心没有返回任何可下载的流。")
                    .font(.callout).foregroundStyle(.tertiary)
            }

            ForEach(Array(qualities.video.enumerated()), id: \.offset) { _, v in
                HStack(spacing: 8) {
                    Text(v.qualityText).font(.callout)
                    Text(v.codec.label)
                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if !v.frameRate.isEmpty {
                        Text(v.frameRate).font(.caption).foregroundStyle(.secondary)
                    }
                    if !v.bitRate.isEmpty {
                        Text(v.bitRate).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Fmt.orDash(v.streamSize)).font(.caption).foregroundStyle(.secondary)
                    Text(v.apiType.label)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            if !qualities.audio.isEmpty {
                Text("音频").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                ForEach(Array(qualities.audio.enumerated()), id: \.offset) { _, a in
                    HStack(spacing: 8) {
                        Text(a.qualityText).font(.callout)
                        Text(a.codecText).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.orDash(a.streamSize)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 清晰度枚举拿不到时的说明。
///
/// `Bvideo.AllQuality` 是唧唧会员功能，非会员一定失败 —— 与其让用户以为
/// 是自己网络出了问题，不如把原因讲清楚。
private struct QualityUnavailableNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("""
                拿不到清晰度列表 —— 核心的 `AllQuality` 接口是唧唧会员功能。\
                下面按 B 站标准清晰度直接选；选了该视频没有的档位，核心会报错，\
                换个档位即可。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 下载参数 + 开始按钮。
private struct DownloadOptions: View {
    @Environment(AppModel.self) private var model
    let page: Jijidown_Core_BvideoPage

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("清晰度").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $model.quality) {
                        ForEach(VideoQuality.allCases) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("编码").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $model.codec) {
                        Text("AVC / H.264").tag(Jijidown_Core_VideoType.avc)
                        Text("HEVC / H.265").tag(Jijidown_Core_VideoType.hevc)
                        Text("AV1").tag(Jijidown_Core_VideoType.av1)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("音质").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $model.audio) {
                        ForEach(AudioQuality.allCases) { a in
                            Text(a.label).tag(a)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                Spacer()

                Button {
                    Task { await model.enqueue(page: page) }
                } label: {
                    Label("开始下载", systemImage: "arrow.down.circle.fill")
                }
                .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Text("""
                    杜比视界需要配合 HEVC 编码。TV / APP 接口是会员功能，\
                    非会员请用 WEB。
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
