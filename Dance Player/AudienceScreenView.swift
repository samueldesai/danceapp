//
//  AudienceScreenView.swift
//  Dance Player
//
//  Created by Samuel Desai on 6/15/26.
//

import SwiftUI

struct PublicDisplayWindowView: View {
    @ObservedObject var player: PlayerController

    private var screenKey: String {
        if player.showThankYouScreen { return "thankYou" }
        if player.isShowingPivots { return "pivots" }
        if player.isBetweenSongs { return "betweenSongs" }
        if player.currentTrack != nil { return "nowPlaying" }
        return "idle"
    }

    var upNextTracks: [Track] {
        let playableTracks = player.tracks.filter { !$0.isSkipped }
        guard let currentIdx = player.currentIndex else {
            return Array(playableTracks.prefix(3))
        }
        guard let nextStartIndex = player.playableIndex(after: currentIdx) else {
            return []
        }
        return Array(player.tracks[nextStartIndex..<player.tracks.count].filter { !$0.isSkipped }.prefix(3))
    }
    
    var body: some View {
        ZStack {
            GeometryReader { geo in
                if player.showThankYouScreen {
                    Color(hex: "#0a0a0c")
                        .transition(.opacity)
                } else if player.isShowingPivots {
                    // Kept bright and saturated so the headline still reads from across the room.
                    ZStack {
                        LinearGradient(
                            colors: [
                                Color(hex: "#ec4899"),
                                Color(hex: "#f97316"),
                                Color(hex: "#fbbf24")
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        RadialGradient(
                            colors: [Color(hex: "#fde68a").opacity(0.85), .clear],
                            center: .init(x: 0.28, y: 0.24),
                            startRadius: 0,
                            endRadius: geo.size.width * 0.55
                        )
                        .blur(radius: 60)

                        RadialGradient(
                            colors: [Color(hex: "#f472b6").opacity(0.6), .clear],
                            center: .init(x: 0.78, y: 0.76),
                            startRadius: 0,
                            endRadius: geo.size.width * 0.5
                        )
                        .blur(radius: 70)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .transition(.opacity)
                } else if let currentTrack = player.currentTrack, let art = currentTrack.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 50)
                        .scaleEffect(1.2)
                        .transition(.opacity)
                } else {
                    Color(hex: "#0c0c0e")
                        .transition(.opacity)
                }
            }
            .edgesIgnoringSafeArea(.all)
            
            Color.black.opacity(player.isShowingPivots ? 0.14 : 0.75)
                .edgesIgnoringSafeArea(.all)

            if player.isShowingPivots {
                pivotCall
                    .transition(.opacity)
            } else if player.showThankYouScreen {
                VStack(spacing: 14) {
                    Text("Thank You For Coming")
                        .font(.system(size: 54, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    Text("The set has finished.")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Color(hex: "#a1a1aa"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else if player.isBetweenSongs {
                            VStack(spacing: 0) {
                                Spacer()
                                
                                if player.currentTrack?.isJam == true {
                                    jamAnnouncement
                                } else {
                                    VStack(spacing: 6) {
                                        Text(player.currentTrack?.nextSongLeadIn ?? "The next song is a")
                                            .font(.system(size: 24, weight: .semibold))
                                            .foregroundColor(Color(hex: "#71717a"))
                                        Text(player.currentTrack?.audienceStylesDisplay.isEmpty == false ? player.currentTrack!.audienceStylesDisplay.uppercased() : "—")
                                            .font(.system(size: 52, weight: .black))
                                            .foregroundColor(Color(hex: "#3478f6"))
                                            .tracking(2)
                                        strangerPrompt
                                    }
                                }
                                
                                Spacer()
                                
                                VStack(spacing: 20) {
                                    Group {
                                        if let art = player.currentTrack?.artwork {
                                            Image(nsImage: art)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            RoundedRectangle(cornerRadius: 14)
                                                .fill(Color(hex: "#1c1c22"))
                                                .overlay(
                                                    Image(systemName: "music.note")
                                                        .font(.system(size: 60))
                                                        .foregroundColor(Color(hex: "#2e2e38"))
                                                )
                                        }
                                    }
                                    .frame(width: 240, height: 240)
                                    .cornerRadius(14)
                                    .shadow(color: Color.black.opacity(0.6), radius: 25, x: 0, y: 10)
                                    
                                    VStack(spacing: 6) {
                                        Text(player.currentTrack?.title ?? "Unknown Title")
                                            .font(.system(size: 32, weight: .bold))
                                            .foregroundColor(.white)
                                            .lineLimit(2)
                                            .minimumScaleFactor(0.6)
                                            .multilineTextAlignment(.center)
                                        Text(player.currentTrack?.artist ?? "Unknown Artist")
                                            .font(.system(size: 20, weight: .medium))
                                            .foregroundColor(Color(hex: "#a1a1aa"))
                                    }
                                }
                                
                                Spacer()

                                VStack(spacing: 12) {
                                    Button(action: {
                                        player.togglePlayPause()
                                    }) {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 18, weight: .medium))
                                            .foregroundColor(.white)
                                            .frame(width: 36, height: 36)
                                            .background(Color.white.opacity(0.1))
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .pointingHandCursor()
                                }
                                .padding(.bottom, 20)
                                
                                Spacer()
                                
                                if let last = player.lastTrack {
                                    VStack(spacing: 12) {
                                        Text("THE LAST SONG WAS")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(Color(hex: "#52525b"))
                                            .tracking(1.5)
                                        
                                        HStack(spacing: 16) {
                                            if let lastArt = last.artwork {
                                                Image(nsImage: lastArt)
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 64, height: 64)
                                                    .cornerRadius(6)
                                            } else {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(Color(hex: "#18181b"))
                                                    .frame(width: 64, height: 64)
                                                    .overlay(Image(systemName: "music.note").font(.system(size: 16)).foregroundColor(Color(hex: "#3f3f46")))
                                            }
                                            
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(last.title)
                                                    .font(.system(size: 16, weight: .bold))
                                                    .foregroundColor(.white)
                                                Text(last.artist)
                                                    .font(.system(size: 13))
                                                    .foregroundColor(Color(hex: "#71717a"))
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 12)
                                        .background(Color(hex: "#111114").opacity(0.6))
                                        .cornerRadius(12)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color(hex: "#242429"), lineWidth: 1)
                                        )
                                    }
                                    .padding(.bottom, 40)
                                } else {
                                    Spacer()
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                        } else if let current = player.currentTrack {
                VStack(spacing: 0) {
                    Spacer()
                    
                    HStack(alignment: .center, spacing: 60) {
                        Group {
                            if let art = current.artwork {
                                Image(nsImage: art)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(hex: "#16161a"))
                                    .overlay(
                                        Image(systemName: "music.note")
                                            .font(.system(size: 80))
                                            .foregroundColor(Color(hex: "#2e2e38"))
                                    )
                            }
                        }
                        // Allowed to shrink below 600 — a hard cap starved the text column on narrower screens.
                        .frame(maxWidth: 600, maxHeight: 600)
                        .aspectRatio(1, contentMode: .fit)
                        .cornerRadius(10)
                        .shadow(color: Color.black.opacity(0.6), radius: 30, x: 0, y: 15)
                        
                        VStack(alignment: .leading, spacing: 0) {
                            // Far wider than the blocks below it — the now-playing title is the
                            // thing the floor reads, so it gets the room before it shrinks.
                            Text(current.title)
                                .font(.system(size: 58, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.45)
                                .truncationMode(.tail)
                                .frame(maxWidth: 900, alignment: .leading)
                                .padding(.bottom, 12)
                        
                            
                            Text(current.artist)
                                .font(.system(size: 28, weight: .medium))
                                .foregroundColor(Color(hex: "#d4d4d8"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .padding(.bottom, 12)
                            
                            if !current.audienceStylesDisplay.isEmpty {
                                Text(current.audienceStylesDisplay)
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(Color(hex: "#d4d4d8"))
                                    .lineLimit(1)
                                    .padding(.bottom, 36)
                            } else {
                                Spacer().frame(height: 50)
                            }

                            if let last = player.lastTrack {
                                Text("LAST PLAYED")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Color(hex: "#a1a1aa"))
                                    .tracking(1.5)
                                    .padding(.bottom, 16)
                                
                                HStack(spacing: 14) {
                                    Group {
                                        if let lastArt = last.artwork {
                                            Image(nsImage: lastArt)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color(hex: "#222226"))
                                                .overlay(
                                                    Image(systemName: "music.note")
                                                        .font(.system(size: 11))
                                                        .foregroundColor(Color(hex: "#44444a"))
                                                )
                                        }
                                    }
                                    .frame(width: 52, height: 52)
                                    .cornerRadius(4)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(last.title)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        
                                        HStack(spacing: 8) {
                                            Text(last.artist)
                                                .font(.system(size: 12))
                                                .foregroundColor(Color(hex: "#a1a1aa"))
                                                .lineLimit(1)
                                            
                                            if !last.audienceStylesDisplay.isEmpty && last.audienceStylesDisplay != "—" {
                                                Text("•")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(Color(hex: "#52525b"))
                                                Text(last.audienceStylesDisplay)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundColor(Color(hex: "#71717a"))
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 36)
                            }
                            
                            Text("UP NEXT")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Color(hex: "#a1a1aa"))
                                .tracking(1.5)
                                .padding(.bottom, 16)
                            
                            VStack(spacing: 14) {
                                if upNextTracks.isEmpty {
                                    Text("No more songs")
                                        .font(.system(size: 13).italic())
                                        .foregroundColor(Color(hex: "#52525b"))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    ForEach(player.upNextTracks) { nextTrack in
                                        HStack(spacing: 14) {
                                            Group {
                                                if let nextArt = nextTrack.artwork {
                                                    Image(nsImage: nextArt)
                                                        .resizable()
                                                        .scaledToFill()
                                                } else {
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .fill(Color(hex: "#222226"))
                                                        .overlay(
                                                            Image(systemName: "music.note")
                                                                .font(.system(size: 11))
                                                                .foregroundColor(Color(hex: "#44444a"))
                                                        )
                                                }
                                            }
                                            .frame(width: 52, height: 52)
                                            .cornerRadius(4)
                                            
                                            // Style leads, and both lines scroll rather than crop.
                                            VStack(alignment: .leading, spacing: 4) {
                                                let style = nextTrack.audienceStylesDisplay
                                                if !style.isEmpty && style != "—" {
                                                    MarqueeText(
                                                        text: style,
                                                        font: .system(size: 16, weight: .semibold),
                                                        color: .white,
                                                        isEnabled: !player.isImportingContent
                                                    )
                                                }

                                                MarqueeText(
                                                    text: "\(nextTrack.title) — \(nextTrack.artist)",
                                                    font: .system(size: 11),
                                                    color: Color(hex: "#a1a1aa"),
                                                    isEnabled: !player.isImportingContent
                                                )
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: 900, alignment: .leading)
                    }
                    .padding(.horizontal, 40)
                    
                    Spacer()
                        VStack(spacing: 20) {
                            VStack(spacing: 10) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.white.opacity(0.12))
                                            .frame(height: 8)
                                        Capsule()
                                            .fill(Color.white.opacity(0.85))
                                            .frame(width: geo.size.width * CGFloat(player.duration > 0 ? player.currentTime / player.duration : 0), height: 8)
                                    }
                                }
                                .frame(height: 4)
                                
                                HStack {
                                    Text(formatTime(player.currentTime))
                                    Spacer()
                                    Text(formatTime(player.duration))
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(hex: "#71717a"))
                            }
                            
                            Button(action: {

                                player.togglePlayPause()
                            }) {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.white.opacity(0.1))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                        .padding(.horizontal, 80)
                        .padding(.bottom, 30)
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 44))
                        .foregroundColor(Color(hex: "#3f3f46"))
                    Text("No Tracks Loaded")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(hex: "#52525b"))
                }
                .transition(.opacity)
            }

            // Last in the ZStack so it falls in front of the artwork and text.
            if showsConfetti {
                ConfettiView()
                    .edgesIgnoringSafeArea(.all)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: screenKey)
        .frame(minWidth: 1024, minHeight: 640)
    }

    func formatTime(_ t: TimeInterval) -> String {
        guard !t.isNaN else { return "0:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Through the jam announcement, through the jam, and through the pivot call that follows
    /// it — the whole celebration rather than just its introduction.
    private var showsConfetti: Bool {
        if player.isShowingPivots { return true }
        guard player.currentTrack?.isJam == true else { return false }
        return player.isBetweenSongs || player.isPlaying
    }

    private var pivotCall: some View {
        Text("Find A Pivot Partner!!!")
            .font(.system(size: 160, weight: .black, design: .rounded))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.4)
            .shadow(color: .black.opacity(0.35), radius: 22, x: 0, y: 8)
            .padding(.horizontal, 60)
    }

    @ViewBuilder
    private var strangerPrompt: some View {
        if player.currentTrack?.isWithStranger == true {
            Text("Find someone you've never danced with and ask them to dance!")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.top, 10)
                .padding(.horizontal, 40)
        }
    }

    private var jamAnnouncement: some View {
        VStack(spacing: 10) {
            Text("The next song is our Jam")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(Color(hex: "#fde68a"))

            Text(jamStyleLine)
                .font(.system(size: 58, weight: .black))
                .foregroundColor(Color(hex: "#f59e0b"))
                .tracking(2)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text("Come to the middle if you have something to celebrate!")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.top, 6)

            strangerPrompt
        }
        .padding(.horizontal, 40)
    }

    /// The dance without the "Jam (…)" wrapper — the line above already says it's the jam.
    private var jamStyleLine: String {
        guard let track = player.currentTrack else { return "" }
        let dance = track.audienceDanceOnlyDisplay
        return (dance.isEmpty || dance == "—") ? "" : "(\(dance.uppercased()))"
    }
}

/// Falling confetti drawn in a single `Canvas` rather than as many views — one draw pass per
/// frame keeps it cheap enough to sit behind a live audience screen.
struct ConfettiView: View {
    private struct Piece {
        let x: Double
        let size: Double
        let aspect: Double
        let fallSeconds: Double
        let phase: Double
        let drift: Double
        let swayAmplitude: Double
        let swayFrequency: Double
        let swayPhase: Double
        let flutterAmplitude: Double
        let flutterFrequency: Double
        let flutterPhase: Double
        let spin: Double
        let spinPhase: Double
        let opacity: Double
        let color: Color
    }

    private let pieces: [Piece]

    /// Independent value per piece per property. Deriving them from `index % n` gives only a
    /// handful of distinct sizes and ties them to horizontal position, which reads as a pattern.
    private static func noise(_ index: Int, _ salt: UInt64) -> Double {
        var x = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
        x = x &+ salt &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 30
        x = x &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27
        x = x &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(1 << 53)
    }

    init(count: Int = 110) {
        let palette = ["#f59e0b", "#3478f6", "#ef4444", "#22c55e", "#e879f9", "#fde68a"]

        pieces = (0..<count).map { index in
            func value(_ salt: UInt64) -> Double { Self.noise(index, salt) }

            let swayFrequency = 0.13 + value(7) * 0.42
            return Piece(
                x: value(1),
                size: 6 + value(2) * 11,
                aspect: 0.3 + value(3) * 0.55,
                fallSeconds: 3.6 + value(4) * 4.8,
                phase: value(5),
                // Slow sideways travel over the fall, so a piece never retraces its own path.
                drift: (value(6) - 0.5) * 34,
                swayAmplitude: 4 + value(8) * 13,
                swayFrequency: swayFrequency,
                swayPhase: value(9) * 2 * .pi,
                // A second, faster sine at an unrelated rate — the sum doesn't visibly repeat.
                flutterAmplitude: 2 + value(10) * 4,
                flutterFrequency: swayFrequency * (1.7 + value(11) * 0.9),
                flutterPhase: value(12) * 2 * .pi,
                spin: (value(13) < 0.5 ? -1 : 1) * (0.12 + value(14) * 0.55),
                spinPhase: value(15) * 2 * .pi,
                opacity: 0.7 + value(16) * 0.3,
                color: Color(hex: palette[Int(value(17) * Double(palette.count)) % palette.count])
            )
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                for piece in pieces {
                    let progress = ((now / piece.fallSeconds) + piece.phase)
                        .truncatingRemainder(dividingBy: 1.0)

                    // Start above the top edge so pieces enter rather than pop into existence.
                    let y = -piece.size + progress * (size.height + piece.size * 2)

                    // Sway runs on wall-clock time rather than fall progress, so it isn't
                    // locked to the fall cycle the way the first version was.
                    let sway = sin(now * piece.swayFrequency * 2 * .pi + piece.swayPhase)
                    let flutter = sin(now * piece.flutterFrequency * 2 * .pi + piece.flutterPhase)
                    let x = piece.x * size.width
                        + piece.drift * progress
                        + sway * piece.swayAmplitude
                        + flutter * piece.flutterAmplitude

                    let height = piece.size * piece.aspect
                    let rect = CGRect(
                        x: -piece.size / 2,
                        y: -height / 2,
                        width: piece.size,
                        height: height
                    )

                    context.drawLayer { layer in
                        layer.translateBy(x: x, y: y)
                        // Slow rotation with a gentle lean. Squashing by abs(cos(spin)) snaps
                        // at every zero crossing, which is what jittered.
                        layer.rotate(by: .radians(
                            now * piece.spin + piece.spinPhase + flutter * 0.12
                        ))
                        layer.fill(Path(rect), with: .color(piece.color.opacity(piece.opacity)))
                    }
                }
            }
        }
    }
}
