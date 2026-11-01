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

    /// Player controls sit over video. visionOS's system glass and bordered
    /// buttons read as bright pills there, so the player gets a dark,
    /// translucent platter that brightens on gaze instead. iOS keeps Liquid Glass.
    @ViewBuilder
    func playerGlass(in shape: some InsettableShape, interactive: Bool = false) -> some View {
        #if os(visionOS)
        background(.black.opacity(0.42), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
        #else
        platformGlass(in: shape, interactive: interactive)
        #endif
    }

    /// `.glassButtonStyle()` for player controls: the dark platter on visionOS.
    @ViewBuilder
    func playerButtonStyle() -> some View {
        #if os(visionOS)
        buttonStyle(PlayerDarkButtonStyle())
        #else
        buttonStyle(.glass)
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

#if os(visionOS)
/// A dark capsule (a circle for square labels) with a hairline edge; dims a
/// little more while pressed and highlights where the user looks.
struct PlayerDarkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(8)
            .background(.black.opacity(configuration.isPressed ? 0.6 : 0.42), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
#endif
