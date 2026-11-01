import SwiftUI

// Liquid Glass (iOS 26) does not exist on visionOS, where every window already
// sits on system glass. These adapters keep the iOS views unconditional: iOS gets
// Liquid Glass, visionOS the nearest native equivalent or nothing.

extension View {
    /// `.buttonStyle(.glass)`; bordered on visionOS.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        #if os(visionOS)
        buttonStyle(.bordered)
        #else
        buttonStyle(.glass)
        #endif
    }

    /// `.buttonStyle(.glassProminent)`; bordered prominent on visionOS.
    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        #if os(visionOS)
        buttonStyle(.borderedProminent)
        #else
        buttonStyle(.glassProminent)
        #endif
    }

    /// `.glassEffect(.regular, in:)`, interactive when asked; the system glass
    /// background on visionOS.
    @ViewBuilder
    func platformGlass(in shape: some InsettableShape, interactive: Bool = false) -> some View {
        #if os(visionOS)
        glassBackgroundEffect(in: shape)
        #else
        glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        #endif
    }

    /// `.scrollEdgeEffectHidden(_:for:)`; visionOS draws no scroll edge effect.
    @ViewBuilder
    func platformScrollEdgeEffectHidden(_ hidden: Bool, for edges: Edge.Set) -> some View {
        #if os(visionOS)
        self
        #else
        scrollEdgeEffectHidden(hidden, for: edges)
        #endif
    }

    /// `.backgroundExtensionEffect()`; nothing on visionOS, which has no bars to
    /// extend artwork under.
    @ViewBuilder
    func platformBackgroundExtensionEffect() -> some View {
        #if os(visionOS)
        self
        #else
        backgroundExtensionEffect()
        #endif
    }
}

/// `GlassEffectContainer`; a plain pass-through on visionOS.
struct PlatformGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        #if os(visionOS)
        content
        #else
        GlassEffectContainer(spacing: spacing) { content }
        #endif
    }
}
