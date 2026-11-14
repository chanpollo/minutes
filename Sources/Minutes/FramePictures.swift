import AppKit
import ImageIO
import SwiftUI

/// A picture opened large over the window.
struct PictureLook: Equatable {
    let url: URL
    let path: String
    let time: TimeInterval?
    let canPlay: Bool
}

/// What a picture on the page can do: play the video from its time, open large.
struct PictureActions {
    let folder: URL
    let canPlay: Bool
    let play: (TimeInterval) -> Void
    let open: (PictureLook) -> Void

    func look(_ path: String) -> PictureLook {
        PictureLook(url: folder.appendingPathComponent(path), path: path, time: Frames.time(of: path), canPlay: canPlay)
    }
}

/// Downscaled pictures, made once per file; full-size frames are several megapixels.
enum FrameThumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ url: URL, maxPixel: Int = 1280) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)#\(maxPixel)#\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary)
        else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(result, forKey: key)
        return result
    }
}

// MARK: Summary

/// A frame under a summary point: 16:9 thumbnail, a time chip that plays from there, click for a larger view.
struct SummaryPicture: View {
    let path: String
    let actions: PictureActions
    @State private var hovered = false

    var body: some View {
        let look = actions.look(path)
        let clock = look.time.map(MeetingFormat.longClock)
        ZStack(alignment: .bottomLeading) {
            Button { actions.open(look) } label: {
                PictureThumbnail(url: look.url, radius: 8)
                    .brightness(hovered ? -0.04 : 0)
                    .animation(.easeOut(duration: 0.15), value: hovered)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("Show larger")
            .accessibilityLabel(clock.map { "Picture at \($0), show larger" } ?? "Picture, show larger")
            if let clock, let time = look.time {
                TimeChip(clock: clock, height: 22, play: look.canPlay ? { actions.play(time) } : nil)
                    .padding(8)
            }
        }
        .frame(width: 320, height: 180)
    }
}

struct PictureThumbnail: View {
    let url: URL
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(Color.primary.opacity(0.06))
            if let image = FrameThumbnails.image(url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        .contentShape(shape)
    }
}

/// `▶ 00:12:34` on a dark plate over a picture; plays from there, or is a plain label when there is no video.
private struct TimeChip: View {
    let clock: String
    let height: CGFloat
    let play: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        if let play {
            Button(action: play) { label }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help("Play from \(clock)")
                .accessibilityLabel("Play from \(clock)")
        } else {
            label.accessibilityLabel(clock)
        }
    }

    private var label: some View {
        HStack(spacing: height > 21 ? 5 : 4) {
            Image(systemName: "play.fill").font(.system(size: height > 21 ? 7 : 6))
            Text(clock).monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .padding(.horizontal, height > 21 ? 7 : 6)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(hovered ? 0.78 : 0.62)))
        .contentShape(Rectangle())
    }
}

// MARK: Larger view

/// The picture large over the window: its file name, Play from its time, and Close (Esc, Space or a click outside).
struct PictureViewer: View {
    let look: PictureLook
    let play: (TimeInterval) -> Void
    let close: () -> Void
    @State private var monitor: Any?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Button(action: close) {
                    Color.black.opacity(0.32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityHidden(true)
                card
                    .frame(width: max(320, min(800, proxy.size.width - 80)))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Esc and Space, as in Quick Look.
                guard event.keyCode == 53 || event.keyCode == 49 else { return event }
                close()
                return nil
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(spacing: 0) {
            ZStack {
                Text((look.path as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                    .accessibilityLabel("Close")
                    Spacer()
                    if look.canPlay, let time = look.time {
                        Button {
                            play(time)
                        } label: {
                            Label("Play from \(MeetingFormat.longClock(time))", systemImage: "play.fill")
                                .monospacedDigit()
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.notesChrome)
            Divider()
            ZStack {
                Color.black
                if let image = FrameThumbnails.image(look.url, maxPixel: 3200) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .accessibilityLabel(look.time.map { "Picture at \(MeetingFormat.longClock($0))" } ?? "Picture")
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
        }
        .background(Color.notesPage)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Picture")
        .accessibilityAddTraits(.isModal)
    }
}
