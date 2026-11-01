// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVKit
import Combine
import SwiftUI
import UIKit

/// One playing item: what the full-screen player shows and what the system
/// controls drive. Plex VOD and Live TV each provide one.
@MainActor
protocol IOSPlaybackSession: AnyObject {
    var player: AetherPlayer { get }
    var nowPlayingItem: IOSNowPlaying.Item { get }
    /// Set by the controller; call it when `nowPlayingItem` changes (next episode, channel switch).
    var onItemChange: (() -> Void)? { get set }
    func begin() async
    /// Final reporting. The controller stops the player afterwards.
    func end()
    func screen(_ controller: IOSPlaybackController) -> AnyView
}

/// App-level owner of the active player, Picture in Picture and Now Playing,
/// so PiP outlives the full-screen view. Starting PiP dismisses the player,
/// PiP's restore button re-presents it, and closing PiP ends playback.
@MainActor
final class IOSPlaybackController: NSObject, ObservableObject {
    @Published var isPresented = false
    @Published private(set) var session: (any IOSPlaybackSession)?
    @Published private(set) var isPictureInPicturePossible = false
    @Published private(set) var isPictureInPictureActive = false

    /// Needed by Plex sessions; the host modifier supplies it.
    weak var plex: IOSPlexSession?

    /// The engine surface, kept here so it survives the view while PiP runs.
    private(set) var surface: UIView?
    private var pip: AVPictureInPictureController?
    private var pipPossibleObservation: AnyCancellable?
    private var isRestoring = false
    private let nowPlaying = IOSNowPlaying()
    private var cancellables = Set<AnyCancellable>()
    #if os(visionOS)
    /// The window's size before playback shaped it to the video, restored on end.
    private var sizeBeforePlayback: CGSize?
    #endif

    // MARK: - Caller API

    /// Plays a Plex item full screen; a playlist's `queue` replaces Up Next.
    func play(_ request: IOSPlexPlaybackRequest, queue: PlayQueue<PlexMetadata>? = nil) {
        guard let plex else { return }
        start(IOSPlexPlayback(request: request, plex: plex, queue: queue))
    }

    func start(_ newSession: any IOSPlaybackSession) {
        end()
        session = newSession
        let player = newSession.player
        let surface = AetherPlayer.makeRenderSurface()
        player.bind(surface: surface)
        self.surface = surface
        newSession.onItemChange = { [weak self] in self?.startNowPlaying() }
        observe(player)
        startNowPlaying()
        isPresented = true
        Task { await newSession.begin() }
    }

    /// Close button: ends playback and leaves the screen.
    func close() {
        end()
        isPresented = false
    }

    /// Swipe down: keep playing in PiP when possible, otherwise close.
    func dismissGesture() {
        if session?.player.state == .playing, isPictureInPicturePossible {
            startPictureInPicture()
        } else {
            close()
        }
    }

    func startPictureInPicture() {
        pip?.startPictureInPicture()
    }

    /// Ends the session: final reports, player stop, PiP and Now Playing torn down.
    func end() {
        guard let session else { return }
        session.end()
        if let surface { session.player.unbind(surface: surface) }
        session.player.stop()
        surface = nil
        pip?.stopPictureInPicture()
        pip?.delegate = nil
        pip = nil
        pipPossibleObservation = nil
        isPictureInPicturePossible = false
        isPictureInPictureActive = false
        nowPlaying.stop()
        cancellables.removeAll()
        UIApplication.shared.isIdleTimerDisabled = false
        self.session = nil
        #if os(visionOS)
        restoreWindowSize()
        #endif
    }

    /// The full-screen cover went away without the close button (PiP start excluded).
    func presentationDismissed() {
        if !isPictureInPictureActive { end() }
    }

    // MARK: - Observation

    private func observe(_ player: AetherPlayer) {
        player.$pictureInPictureSource
            .sink { [weak self] source in self?.updatePictureInPicture(source) }
            .store(in: &cancellables)

        // Now Playing and the idle timer follow transport changes, not clock ticks.
        Publishers.Merge4(
            player.$state.map { _ in () },
            player.$rate.map { _ in () },
            player.$pendingSeekTarget.map { _ in () },
            player.$duration.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.transportChanged() }
        .store(in: &cancellables)

        #if os(visionOS)
        // The window is the screen on Vision Pro: shape it to the picture so
        // there are no bars, whatever the film's aspect ratio.
        player.$videoSize
            .removeDuplicates()
            .filter { $0.width > 0 && $0.height > 0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.fitWindow(to: $0) }
            .store(in: &cancellables)
        #endif
    }

    #if os(visionOS)
    private var windowScene: UIWindowScene? {
        surface?.window?.windowScene
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
    }

    /// Keeps the window's width, sets the height from the video's aspect ratio,
    /// and holds that ratio while the window is resized.
    private func fitWindow(to video: CGSize) {
        guard let scene = windowScene else { return }
        let current = scene.coordinateSpace.bounds.size
        guard current.width > 0 else { return }
        if sizeBeforePlayback == nil { sizeBeforePlayback = current }
        let aspect = video.width / video.height
        let width = max(current.width, 1280)
        let size = CGSize(width: width, height: (width / aspect).rounded())
        requestWindow(size, restrictions: .uniform, in: scene)
    }

    private func requestWindow(_ size: CGSize, restrictions: UIWindowScene.ResizingRestrictions, in scene: UIWindowScene) {
        let preferences = UIWindowScene.GeometryPreferences.Vision()
        preferences.size = size
        preferences.resizingRestrictions = restrictions
        scene.requestGeometryUpdate(preferences) { _ in }
    }

    private func restoreWindowSize() {
        guard let size = sizeBeforePlayback, let scene = windowScene else { return }
        sizeBeforePlayback = nil
        requestWindow(size, restrictions: .freeform, in: scene)
    }
    #endif

    private func transportChanged() {
        guard let player = session?.player else { return }
        let playing = player.state == .playing
        UIApplication.shared.isIdleTimerDisabled = playing
        nowPlaying.update(
            elapsed: player.pendingSeekTarget ?? player.currentTime,
            duration: player.duration,
            rate: playing ? player.rate : 0
        )
        // Sample-buffer PiP re-reads paused state and range only when told.
        if let pip, pip.contentSource?.sampleBufferDisplayLayer != nil { pip.invalidatePlaybackState() }
    }

    private func startNowPlaying() {
        guard let session else { return }
        let player = session.player
        let defaults = UserDefaults.standard
        let back = Double(defaults.object(forKey: "playerSkipBackwardSeconds") as? Int ?? 10)
        let forward = Double(defaults.object(forKey: "playerSkipForwardSeconds") as? Int ?? 30)
        let item = session.nowPlayingItem
        nowPlaying.start(
            item,
            commands: IOSNowPlaying.Commands(
                play: { [weak player] in player?.play() },
                pause: { [weak player] in player?.pause() },
                skip: { [weak player] seconds in Task { await player?.skip(by: seconds) } },
                seek: item.isLive ? nil : { [weak player] time in Task { await player?.seek(to: time) } }
            ),
            skipBackward: back,
            skipForward: forward
        )
        transportChanged()
    }

    // MARK: - Picture in Picture

    private func updatePictureInPicture(_ source: AVPictureInPictureController.ContentSource?) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if let pip {
            // Keep a live window through the teardown's transient nil; a new layer replaces a dead one.
            if source != nil || !pip.isPictureInPictureActive { pip.contentSource = source }
            return
        }
        guard let source else { return }
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipPossibleObservation = controller.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isPictureInPicturePossible = $0 }
        pip = controller
    }
}

extension IOSPlaybackController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isPictureInPictureActive = true
        session?.player.setPictureInPictureActive(true)
        isPresented = false
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        isRestoring = true
        guard !isPresented else {
            completionHandler(true)
            return
        }
        isPresented = true
        // Let the cover finish presenting so the window animates into it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            completionHandler(true)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isPictureInPictureActive = false
        session?.player.setPictureInPictureActive(false)
        // Re-apply anything withheld while the window was up.
        controller.contentSource = session?.player.pictureInPictureSource
        defer { isRestoring = false }
        guard !isRestoring else { return }
        // The window's close button: end playback, or pause if the player is still on screen.
        if !isPresented {
            end()
        } else {
            session?.player.pause()
        }
    }
}

extension View {
    /// Applied once at the app root, inside the `IOSPlexSession` environment:
    /// presents the controller's player full screen.
    func iosPlaybackHost(_ controller: IOSPlaybackController) -> some View {
        modifier(IOSPlaybackHost(controller: controller))
    }
}

private struct IOSPlaybackHost: ViewModifier {
    @ObservedObject var controller: IOSPlaybackController
    @EnvironmentObject private var plex: IOSPlexSession

    func body(content: Content) -> some View {
        content
            .environmentObject(controller)
            .onAppear { controller.plex = plex }
            .fullScreenCover(isPresented: $controller.isPresented, onDismiss: controller.presentationDismissed) {
                if let session = controller.session {
                    session.screen(controller)
                }
            }
    }
}

/// The engine surface, re-parented into whichever screen is showing it.
struct IOSPlayerSurface: UIViewRepresentable {
    let surface: UIView?

    final class Container: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            subviews.forEach { $0.frame = bounds }
        }
    }

    func makeUIView(context: Context) -> Container {
        let container = Container()
        container.backgroundColor = .black
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        guard let surface, surface.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(surface)
        container.setNeedsLayout()
    }
}
