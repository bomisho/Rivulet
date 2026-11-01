// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

#if os(visionOS)
import Combine
import RealityKit
import SwiftUI

/// How the player sits in the room on Vision Pro. The player window stays the
/// screen in every mode; the immersive ones surround it with an environment
/// and enlarge it (`IOSPlaybackController.fitWindow`).
enum TheaterMode: String, CaseIterable, Identifiable {
    case window, dimmed, cinema, nightSky, void

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .window: "Window"
        case .dimmed: "Dimmed Room"
        case .cinema: "Cinema"
        case .nightSky: "Night Sky"
        case .void: "Void"
        }
    }

    var systemImage: String {
        switch self {
        case .window: "rectangle"
        case .dimmed: "moon"
        case .cinema: "theatermasks"
        case .nightSky: "sparkles"
        case .void: "circle.fill"
        }
    }

    var isImmersive: Bool { self == .cinema || self == .nightSky || self == .void }
}

/// The chosen mode (remembered across launches) and whether the theater space is open.
@MainActor
final class VisionTheater: ObservableObject {
    static let shared = VisionTheater()
    static let spaceID = "rivulet.theater"
    private static let modeKey = "visionTheaterMode"

    @Published var mode: TheaterMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    private var isSpaceOpen = false
    private var isTransitioning = false

    private init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(TheaterMode.init) ?? .window
    }

    /// Opens or closes the space to match `mode`.
    func apply(open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction) async {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        if mode.isImmersive, !isSpaceOpen {
            switch await open(id: Self.spaceID) {
            case .opened: isSpaceOpen = true
            default: mode = .window   // refused or cancelled: fall back to the plain window
            }
        } else if !mode.isImmersive, isSpaceOpen {
            await dismiss()
            isSpaceOpen = false
        }
    }

    /// The player closed: leave the theater, keep the choice for next time.
    func leave(dismiss: DismissImmersiveSpaceAction) async {
        guard isSpaceOpen else { return }
        await dismiss()
        isSpaceOpen = false
    }

    /// The system closed the space (Digital Crown, Home).
    func spaceDidClose() {
        isSpaceOpen = false
        if mode.isImmersive { mode = .window }
    }
}

// MARK: - Player side

extension View {
    /// Applied to the player chrome: dims the room or opens the theater space
    /// while the player is on screen.
    func visionTheaterHost() -> some View { modifier(VisionTheaterHost()) }
}

private struct VisionTheaterHost: ViewModifier {
    @ObservedObject private var theater = VisionTheater.shared
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace

    func body(content: Content) -> some View {
        content
            .preferredSurroundingsEffect(theater.mode == .dimmed ? .systemDark : nil)
            .task { await theater.apply(open: openSpace, dismiss: dismissSpace) }
            .onChange(of: theater.mode) {
                Task { await theater.apply(open: openSpace, dismiss: dismissSpace) }
            }
            .onDisappear {
                Task { await theater.leave(dismiss: dismissSpace) }
            }
    }
}

/// The player's theater button.
struct TheaterMenu: View {
    @ObservedObject private var theater = VisionTheater.shared

    var body: some View {
        Menu {
            Picker("Theater", selection: $theater.mode) {
                ForEach(TheaterMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "theatermasks")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .playerGlass(in: .circle, interactive: true)
        .accessibilityLabel("Theater")
        .accessibilityValue(Text(theater.mode.title))
    }
}

// MARK: - The space

/// Full immersion around the player window: a large sphere seen from inside,
/// painted with the chosen environment.
struct TheaterSpaceView: View {
    @ObservedObject private var theater = VisionTheater.shared

    var body: some View {
        RealityView { content in
            let root = Entity()
            root.name = "theaterRoot"
            content.add(root)
            TheaterEnvironment.show(theater.mode, in: root)
        } update: { content in
            guard let root = content.entities.first(where: { $0.name == "theaterRoot" }) else { return }
            TheaterEnvironment.show(theater.mode, in: root)
        }
        .onDisappear { theater.spaceDidClose() }
    }
}

@MainActor
private enum TheaterEnvironment {
    private static var textures: [TheaterMode: TextureResource] = [:]

    static func show(_ mode: TheaterMode, in root: Entity) {
        let showing = mode.isImmersive ? mode : .void   // the space closes right after
        guard root.children.first?.name != showing.rawValue else { return }
        root.children.removeAll()
        let sphere = ModelEntity(mesh: .generateSphere(radius: 400), materials: [material(for: showing)])
        sphere.name = showing.rawValue
        // Mirrored on one axis so the inside faces are the visible ones.
        sphere.scale = SIMD3(-1, 1, 1)
        root.addChild(sphere)
    }

    private static func material(for mode: TheaterMode) -> UnlitMaterial {
        guard mode != .void else { return UnlitMaterial(color: UIColor(white: 0.015, alpha: 1)) }
        var material = UnlitMaterial()
        if let texture = texture(for: mode) {
            material.color = .init(tint: .white, texture: .init(texture))
        } else {
            material.color = .init(tint: UIColor(white: 0.02, alpha: 1))
        }
        return material
    }

    private static func texture(for mode: TheaterMode) -> TextureResource? {
        if let cached = textures[mode] { return cached }
        guard let image = mode == .cinema ? TheaterArt.cinema() : TheaterArt.nightSky(),
              let texture = try? TextureResource(image: image, options: .init(semantic: .color))
        else { return nil }
        textures[mode] = texture
        return texture
    }
}

/// Equirectangular environment images, drawn in code so the app ships no art.
private enum TheaterArt {
    static let size = CGSize(width: 4096, height: 2048)

    private static func draw(_ body: (CGContext) -> Void) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { body($0.cgContext) }.cgImage
    }

    private static func gradient(_ ctx: CGContext, from top: UIColor, to bottom: UIColor, y0: CGFloat, y1: CGFloat) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])
        else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: y0, width: size.width, height: y1 - y0))
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
        ctx.restoreGState()
    }

    /// A dark auditorium: black ceiling, deep red pleated curtains all round, a dim floor.
    static func cinema() -> CGImage? {
        draw { ctx in
            let h = size.height, w = size.width
            gradient(ctx, from: UIColor(white: 0.0, alpha: 1), to: UIColor(red: 0.05, green: 0.01, blue: 0.015, alpha: 1),
                     y0: 0, y1: h * 0.38)
            // Curtains: one column per pixel, shaded by a pleat wave.
            let top = h * 0.38, bottom = h * 0.6
            for x in stride(from: 0, to: Int(w), by: 2) {
                let pleat = 0.55 + 0.45 * sin(Double(x) / w * .pi * 2 * 90)
                let fold = 0.85 + 0.15 * sin(Double(x) / w * .pi * 2 * 7)
                let k = CGFloat(pleat * fold)
                ctx.setFillColor(UIColor(red: 0.30 * k, green: 0.025 * k, blue: 0.04 * k, alpha: 1).cgColor)
                ctx.fill(CGRect(x: CGFloat(x), y: top, width: 2, height: bottom - top))
            }
            // Soft shadow where the curtains meet ceiling and floor.
            gradient(ctx, from: UIColor(white: 0, alpha: 0.9), to: UIColor(white: 0, alpha: 0), y0: top, y1: top + h * 0.05)
            gradient(ctx, from: UIColor(white: 0, alpha: 0), to: UIColor(white: 0, alpha: 0.85), y0: bottom - h * 0.06, y1: bottom)
            gradient(ctx, from: UIColor(red: 0.035, green: 0.012, blue: 0.012, alpha: 1), to: UIColor(white: 0.0, alpha: 1),
                     y0: bottom, y1: h)
        }
    }

    /// Stars over a faint horizon glow, dark ground below.
    static func nightSky() -> CGImage? {
        draw { ctx in
            let h = size.height, w = size.width
            gradient(ctx, from: UIColor(red: 0.0, green: 0.0, blue: 0.02, alpha: 1),
                     to: UIColor(red: 0.04, green: 0.05, blue: 0.12, alpha: 1), y0: 0, y1: h * 0.5)
            gradient(ctx, from: UIColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1), to: UIColor(white: 0, alpha: 1),
                     y0: h * 0.5, y1: h)
            var rng = SplitMix64(seed: 0x5249_5655_4C45_54)   // fixed sky, same every time
            for _ in 0..<5200 {
                let y = CGFloat(Double(rng.next() % 1000) / 1000) * h * 0.5
                let x = CGFloat(Double(rng.next() % 10000) / 10000) * w
                let r = CGFloat(rng.next() % 100) < 6 ? 2.6 : (CGFloat(rng.next() % 100) < 25 ? 1.6 : 1.0)
                let a = 0.35 + Double(rng.next() % 65) / 100
                ctx.setFillColor(UIColor(white: 1, alpha: a).cgColor)
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
            }
        }
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
