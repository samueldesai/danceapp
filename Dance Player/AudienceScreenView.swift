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
        if player.isBetweenSongs { return "betweenSongs" }
        if player.currentTrack != nil { return "nowPlaying" }
        return "idle"
    }

    var upNextTracks: [Track] {
        guard let currentIdx = player.currentIndex else {
            return Array(player.tracks.prefix(3))
        }
        let nextStartIndex = currentIdx + 1
        guard nextStartIndex < player.tracks.count else {
            return []
        }
        return Array(player.tracks[nextStartIndex..<min(nextStartIndex + 3, player.tracks.count)])
    }
    
    var body: some View {
        ZStack {
            GeometryReader { geo in
                if player.showThankYouScreen {
                    Color(hex: "#0a0a0c")
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
            
            Color.black.opacity(0.75)
                .edgesIgnoringSafeArea(.all)

            if player.showThankYouScreen {
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
                                
                                VStack(spacing: 6) {
                                    Text("The next song is a")
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundColor(Color(hex: "#71717a"))
                                    Text(player.currentTrack?.formattedStylesDisplay.isEmpty == false ? player.currentTrack!.formattedStylesDisplay.uppercased() : "—")
                                        .font(.system(size: 52, weight: .black))
                                        .foregroundColor(Color(hex: "#3478f6"))
                                        .tracking(2)
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
                        .frame(width: 600, height: 600)
                        .cornerRadius(10)
                        .shadow(color: Color.black.opacity(0.6), radius: 30, x: 0, y: 15)
                        
                        VStack(alignment: .leading, spacing: 0) {
                            Text(current.title)
                                .font(.system(size: 40, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.5)
                                .truncationMode(.tail)
                                .padding(.bottom, 12)
                        
                            
                            Text(current.artist)
                                .font(.system(size: 22, weight: .medium))
                                .foregroundColor(Color(hex: "#d4d4d8"))
                                .lineLimit(1)
                                .padding(.bottom, 12)
                            
                            if !current.formattedStylesDisplay.isEmpty {
                                Text(current.formattedStylesDisplay)
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
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        
                                        HStack(spacing: 8) {
                                            Text(last.artist)
                                                .font(.system(size: 12))
                                                .foregroundColor(Color(hex: "#a1a1aa"))
                                                .lineLimit(1)
                                            
                                            if !last.formattedStylesDisplay.isEmpty && last.formattedStylesDisplay != "—" {
                                                Text("•")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(Color(hex: "#52525b"))
                                                Text(last.formattedStylesDisplay)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundColor(Color(hex: "#71717a"))
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .frame(maxWidth: 380)
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
                                            
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(nextTrack.title)
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)
                                                
                                                HStack(spacing: 8) {
                                                    Text(nextTrack.artist)
                                                        .font(.system(size: 12))
                                                        .foregroundColor(Color(hex: "#a1a1aa"))
                                                        .lineLimit(1)
                                                    if !nextTrack.formattedStylesDisplay.isEmpty && nextTrack.formattedStylesDisplay != "—" {
                                                        Text("•")
                                                            .font(.system(size: 10))
                                                            .foregroundColor(Color(hex: "#52525b"))
                                                        Text(nextTrack.formattedStylesDisplay)
                                                            .font(.system(size: 11, weight: .medium))
                                                            .foregroundColor(Color(hex: "#71717a"))
                                                    }
                                                }
                                            }
                                            Spacer()
                                        }
                                        .frame(maxWidth: 380)
                                    }
                                }
                            }
                        }
                        .frame(width: 600, alignment: .leading)
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
}
