import AppKit
import SwiftUI

/// Under "Summarised by Claude…": Listen, then the making strip, then the briefing's own player and its text.
struct BriefingRow: View {
    @ObservedObject var center = BriefingCenter.shared
    let item: MeetingItem
    let hasSummary: Bool
    @State private var showText = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduced: Bool { Motion.reduced(systemReduceMotion) }

    var body: some View {
        let state = center.state(of: item, hasSummary: hasSummary)
        Group {
            switch state {
            case .hidden:
                EmptyView()
            case .none:
                listen
            case .making(let phase):
                making(phase)
            case .ready(let info, let stale):
                player(info, stale: stale)
            }
        }
        .transition(.opacity)
        .animation(reduced ? nil : Motion.appear, value: Kind(state))
    }

    private enum Kind: Equatable {
        case hidden, none, making, ready

        init(_ state: BriefingCenter.State) {
            switch state {
            case .hidden: self = .hidden
            case .none: self = .none
            case .making: self = .making
            case .ready: self = .ready
            }
        }
    }

    private var listen: some View {
        Button {
            center.listen(item.id)
        } label: {
            Label("Listen", systemImage: "speaker.wave.2")
        }
        .controlSize(.regular)
        .disabled(center.recording)
        .help(center.recording ? "Not while recording" : "Make a spoken briefing of this summary on this Mac and play it")
    }

    private func making(_ phase: BriefingCenter.Phase) -> some View {
        HStack(spacing: 10) {
            BriefingSpinner(reduced: reduced)
                .frame(width: 14, height: 14)
            switch phase {
            case .script:
                Text("Writing the script…").foregroundStyle(.secondary)
            case .audio(let value):
                Text("Making the audio · \(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                BriefingBar(value: value)
                    .frame(width: 160, height: 4)
            }
            Spacer(minLength: 0)
            Button("Cancel") { center.cancel(item.id) }
                .controlSize(.small)
                .disabled(center.saving.contains(item.id))
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(BriefingBox())
        .accessibilityElement(children: .contain)
    }

    private func player(_ info: BriefingInfo, stale: Bool) -> some View {
        let id = item.id
        let loaded = center.loadedID == id
        let total = loaded && center.duration > 0 ? center.duration : info.duration
        let time = center.position(id)
        let playing = center.isPlaying(id)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    center.toggle(id)
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.notesPage)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(center.recording && !playing)
                .help(center.recording ? "Not while recording" : playing ? "Pause" : "Play")
                .accessibilityLabel(playing ? "Pause briefing" : "Play briefing")
                Text("Briefing").fontWeight(.semibold)
                Text(BriefingCenter.clock(time))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
                BriefingScrubber(value: time, total: total, reduced: reduced) { center.seek(id, to: $0) }
                Text(BriefingCenter.clock(total))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    center.cycleSpeed()
                } label: {
                    Text(Self.speedLabel(center.speed)).monospacedDigit().frame(minWidth: 32)
                }
                .controlSize(.small)
                .accessibilityLabel("Playback speed \(Self.speedLabel(center.speed))")
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1, height: 18)
                    .accessibilityHidden(true)
                Button {
                    Motion.animate(reduced ? nil : Motion.appear) { showText.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showText ? 90 : 0))
                        Text(showText ? "Hide text" : "Show text")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(showText ? .isSelected : [])
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            if stale {
                Divider()
                staleBar(info)
            }
            if showText {
                Divider()
                BriefingText(center: center, item: item, info: info, stale: stale, reduced: reduced)
                    .transition(reduced ? .opacity : .opacity.combined(with: .offset(y: -4)))
            }
        }
        .background(BriefingBox())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func staleBar(_ info: BriefingInfo) -> some View {
        let meta = item.meta
        let when = meta.summarizedAt.map { MeetingFormat.when($0, since: meta.startedAt) } ?? ""
        return HStack(spacing: 10) {
            (Text("Out of date").fontWeight(.semibold).foregroundColor(.briefingWarn)
                + Text(" · made before the summary was re-run \(when)").foregroundColor(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Make Again") { center.make(item.id, autoplay: false, again: true) }
                .controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
    }

    static func speedLabel(_ step: Int) -> String {
        ["1×", "1.25×", "1.5×"][min(2, max(0, step))]
    }
}

/// briefing.md, one block per paragraph; the sentence being spoken is lit, and a click plays from it.
private struct BriefingText: View {
    @ObservedObject var center: BriefingCenter
    let item: MeetingItem
    let info: BriefingInfo
    let stale: Bool
    let reduced: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let paragraphs = center.paragraphs(item, madeAt: info.madeAt)
        let current = currentSentence
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(offsets(paragraphs).enumerated()), id: \.offset) { index, first in
                    Text(attributed(paragraphs[index], first: first, current: current))
                        .font(.reading)
                        .lineSpacing(6)
                        .tint(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "minutes-briefing", let index = Int(url.host() ?? ""), info.marks.indices.contains(index) else {
                    return .discarded
                }
                center.seek(item.id, to: info.marks[index], play: true)
                return .handled
            })
            .animation(reduced ? nil : Motion.fade, value: current)
            HStack(spacing: 10) {
                Text("\(info.voice) · \(BriefingCenter.clock(info.duration)) · made at \(MeetingFormat.time(info.madeAt)) · \(Briefing.scriptName)")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !stale {
                    Button("Make Again") { center.make(item.id, autoplay: false, again: true) }
                        .controlSize(.small)
                        .help("Speak the script again with the voice and rate in Settings")
                }
            }
            .font(.system(size: 12))
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The sentence the playhead is in, once this briefing has started.
    private var currentSentence: Int? {
        guard center.loadedID == item.id, center.isPlaying || center.time > 0 else { return nil }
        let time = center.time
        return info.marks.lastIndex { $0 <= time + 0.05 }
    }

    private func offsets(_ paragraphs: [[String]]) -> [Int] {
        var first = 0
        return paragraphs.map { sentences in
            defer { first += sentences.count }
            return first
        }
    }

    private func attributed(_ sentences: [String], first: Int, current: Int?) -> AttributedString {
        var out = AttributedString()
        for (offset, sentence) in sentences.enumerated() {
            let index = first + offset
            var part = AttributedString(sentence)
            part.link = URL(string: "minutes-briefing://\(index)")
            if index == current { part.backgroundColor = Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.12) }
            if offset > 0 { out += AttributedString(" ") }
            out += part
        }
        return out
    }
}

/// 4 pt track, accent fill, a white knob on hover or focus; arrows step 5 s.
struct BriefingScrubber: View {
    let value: TimeInterval
    let total: TimeInterval
    let reduced: Bool
    let seek: (TimeInterval) -> Void
    @State private var hovering = false
    @State private var dragging: TimeInterval?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let shown = dragging ?? value
            let fraction = total > 0 ? min(1, max(0, shown / total)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: max(0, fraction * width), height: 4)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.28), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .frame(width: 12, height: 12)
                    .offset(x: fraction * width - 6)
                    .opacity(hovering || focused || dragging != nil ? 1 : 0)
                    .animation(reduced ? nil : .easeOut(duration: 0.15 * Motion.timeScale), value: hovering || focused || dragging != nil)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragging = time(at: $0.location.x, width: width) }
                .onEnded {
                    seek(time(at: $0.location.x, width: width))
                    dragging = nil
                })
        }
        .frame(height: 20)
        .onHover { hovering = $0 }
        .focusable()
        .focused($focused)
        .onKeyPress(.leftArrow) {
            seek(max(0, value - 5))
            return .handled
        }
        .onKeyPress(.rightArrow) {
            seek(min(total, value + 5))
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Briefing position")
        .accessibilityValue("\(BriefingCenter.spoken(value)) of \(BriefingCenter.spoken(total))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(min(total, value + 5))
            case .decrement: seek(max(0, value - 5))
            @unknown default: break
            }
        }
    }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return min(1, max(0, x / width)) * total
    }
}

/// The making strip's progress: a 4 pt accent bar.
private struct BriefingBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule().fill(Color.accentColor).frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A quarter ring that turns; it stands still under Reduce Motion.
struct BriefingSpinner: View {
    let reduced: Bool
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.16), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .padding(1)
        .onAppear {
            guard !reduced else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityHidden(true)
    }
}

/// The rounded box the strip and the player sit in, on the side column's background.
private struct BriefingBox: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.notesAside)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

extension Color {
    /// #a34a00 on light, the system orange on dark: "Out of date".
    static let briefingWarn = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.624, blue: 0.039, alpha: 1) : NSColor(srgbRed: 0.639, green: 0.29, blue: 0, alpha: 1)
    })
}
