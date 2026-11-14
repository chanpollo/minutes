import AppKit
import SwiftUI

/// Timings shared by every animated change. Under Reduce Motion, moves and scales become plain fades or nothing.
enum Motion {
    /// Stretches every duration; the render harness slows motion down to sample its frames.
    static var timeScale: Double = 1
    /// Stands in for the system setting in tests and renders.
    static var reduceOverride: Bool?

    static var reduceMotion: Bool {
        reduceOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// For views: pass `@Environment(\.accessibilityReduceMotion)`.
    static func reduced(_ system: Bool) -> Bool {
        reduceOverride ?? system
    }

    static var appearDuration: TimeInterval { 0.2 * timeScale }
    static var fadeDuration: TimeInterval { 0.15 * timeScale }

    /// Appear and state changes.
    static var appear: Animation { .easeOut(duration: appearDuration) }
    /// Disappear, page and tab crossfades.
    static var fade: Animation { .easeOut(duration: fadeDuration) }
    /// Drag, reorder, inserts and deletes in a list, selection.
    static var spring: Animation { .spring(response: 0.3 * timeScale, dampingFraction: 0.85) }
    /// A selected row's text, once the selection spring has mostly arrived.
    static var textFollowsFill: Animation { .easeOut(duration: 0.1 * timeScale).delay(0.15 * timeScale) }
    /// Level meters follow the audio within one tick.
    static var meter: Animation { .linear(duration: 0.1 * timeScale) }

    /// The spring for rows that move; with motion reduced, rows take their new place at once.
    static func move(reduced: Bool = reduceMotion) -> Animation? {
        reduced ? nil : spring
    }

    /// For `.animation(_:value:)` on state changes: none with Reduce Motion.
    static var settle: Animation? { reduceMotion ? nil : appear }

    /// `withAnimation`, skipped when `animation` is nil.
    @discardableResult
    static func animate<Result>(_ animation: Animation?, _ body: () throws -> Result) rethrows -> Result {
        guard let animation else { return try body() }
        return try withAnimation(animation, body)
    }

    /// AppKit animator changes with an ease-out curve; without animation the changes apply at once.
    static func run(
        _ duration: TimeInterval, animated: Bool = true, _ changes: @escaping (NSAnimationContext) -> Void,
        completion: (() -> Void)? = nil
    ) {
        guard animated else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                changes(context)
            }
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            changes(context)
        }, completionHandler: completion)
    }

    /// A row coming in from above, or only fading in when motion is reduced.
    static func rowInsertion(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .opacity.combined(with: .offset(y: -8))
    }

    /// A row fading and collapsing towards its top edge.
    static func rowRemoval(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .modifier(active: Collapse(amount: 0), identity: Collapse(amount: 1))
    }

    static func row(reduced: Bool) -> AnyTransition {
        .asymmetric(insertion: rowInsertion(reduced: reduced), removal: rowRemoval(reduced: reduced))
    }

    /// Slides a few points as it fades; a plain fade when motion is reduced.
    static func slide(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .opacity.combined(with: .offset(y: -6))
    }

    /// Shrinks the row's height to nothing, clipping its text rather than squeezing it, as it fades.
    private struct Collapse: ViewModifier, Animatable {
        var amount: CGFloat
        @State private var height: CGFloat?

        var animatableData: CGFloat {
            get { amount }
            set { amount = newValue }
        }

        func body(content: Content) -> some View {
            content
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { height = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, new in height = new }
                })
                .frame(height: amount < 1 ? height.map { $0 * max(amount, 0) } : nil, alignment: .top)
                .clipped()
                .opacity(Double(amount * amount))
        }
    }
}
