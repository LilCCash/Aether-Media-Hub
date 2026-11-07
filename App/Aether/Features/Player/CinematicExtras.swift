import SwiftUI
import AVFoundation
import AetherCore

// MARK: - Original opening sound

/// A short chime made here, note by note: three soft tones that rise over a low swell. Nothing is sampled from a film or a song.
@MainActor
final class OpeningSound {
    static let shared = OpeningSound()
    private var player: AVAudioPlayer?

    func play() {
        guard let data = OpeningSound.wav() else { return }
        player = try? AVAudioPlayer(data: data)
        player?.volume = 0.7
        player?.prepareToPlay()
        player?.play()
    }

    func stop() { player?.stop(); player = nil }

    /// 16-bit mono WAV, 44.1 kHz, 1.7 seconds: a light riser. Air (filtered noise whose brightness opens up) and a thin rising tone that swell
    /// together and let go in a soft tail. Made here, sample by sample: nothing is taken from a film or a song.
    static func wav() -> Data? {
        let rate = 44_100.0
        let seconds = 1.7
        let rise = 1.35
        let count = Int(rate * seconds)
        var samples = [Int16](repeating: 0, count: count)
        var seed: UInt32 = 0x2F6E_2B1
        var low = 0.0
        var phase = 0.0
        for index in 0..<count {
            let t = Double(index) / rate
            // Noise (a simple linear generator is plenty for air) through a low-pass that opens from 400 Hz to 7 kHz.
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let progress = min(1, t / rise)
            let cutoff = 400 + 6_600 * progress * progress
            let alpha = 1 - exp(-2 * .pi * cutoff / rate)
            low += alpha * (noise - low)
            // A thin tone gliding from 330 Hz to 990 Hz.
            let freq = 330 + 660 * progress * progress
            phase += 2 * .pi * freq / rate
            let tone = sin(phase) * 0.5 + sin(phase * 2) * 0.12
            // Swell up to the top of the riser, then a quick soft release.
            let swell = t < rise ? pow(progress, 2.2) : exp(-(t - rise) * 9)
            let attack = min(1, t / 0.05)
            let fade = min(1, (seconds - t) / 0.15)
            let value = (low * 0.55 + tone * 0.16) * swell * attack * fade
            samples[index] = Int16(max(-1, min(1, value)) * 28_000)
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        let dataSize = UInt32(count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + dataSize); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        for sample in samples { append(sample) }
        return data
    }
}

// MARK: - Opening

/// A few seconds before the film: the title comes out of the dark between two lines of light, with the chime. A tap skips it.
struct CinematicOpeningView: View {
    let title: String
    let onFinish: () -> Void
    @EnvironmentObject private var settings: SettingsStore
    @State private var phase = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [settings.accentColor.opacity(0.4), .clear], center: .center, startRadius: 10, endRadius: 380)
                .opacity(phase >= 1 ? 1 : 0).ignoresSafeArea()
            VStack(spacing: 16) {
                line
                Text(title.uppercased())
                    .font(.system(size: 30, weight: .heavy, design: .serif))
                    .tracking(phase >= 1 ? 5 : 20)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .opacity(phase >= 1 ? 1 : 0)
                    .padding(.horizontal, 40)
                line
            }
        }
        .opacity(phase >= 2 ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task {
            if settings.value.appearance.openingSound { OpeningSound.shared.play() }
            withAnimation(.easeOut(duration: 1.6)) { phase = 1 }
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            withAnimation(.easeIn(duration: 0.45)) { phase = 2 }
            try? await Task.sleep(nanoseconds: 450_000_000)
            finish()
        }
        .accessibilityLabel("Apertura: \(title). Tocca per saltare.")
    }

    private var line: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear, settings.accentColor, .clear], startPoint: .leading, endPoint: .trailing))
            .frame(width: phase >= 1 ? 340 : 0, height: 2)
    }

    private func finish() {
        OpeningSound.shared.stop()
        onFinish()
    }
}

// MARK: - Credits experience

/// When the film is over: the credits roll over a dark page with the people of the film, then a quote and what to watch next.
struct CreditsExperienceView: View {
    let meta: MetaItem
    let onClose: () -> Void
    let onOpen: (MetaRoute) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @State private var similar: [TitleRichDetails.Similar] = []
    @State private var rolled = false
    @State private var opening = false
    private let quote = Quotes.all.randomElement()

    private var lines: [(role: String, names: [String])] {
        var result: [(String, [String])] = []
        if !meta.directors.isEmpty { result.append(("Regia", meta.directors)) }
        if !meta.cast.isEmpty { result.append(("Interpreti", meta.cast)) }
        if !meta.writers.isEmpty { result.append(("Scritto da", meta.writers)) }
        return result
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let background = meta.background ?? meta.poster {
                RemoteImage(urlString: background, width: 900, placeholderSeed: meta.name).opacity(0.18).blur(radius: 12).ignoresSafeArea()
            }
            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 26) {
                        Text("FINE").font(.system(size: 13, weight: .bold)).tracking(6).foregroundStyle(.white.opacity(0.6))
                        Text(meta.name).font(.aetherTitle(34)).foregroundStyle(.white).multilineTextAlignment(.center)
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, group in
                            VStack(spacing: 6) {
                                Text(group.role.uppercased()).font(.system(size: 11, weight: .bold)).tracking(3).foregroundStyle(settings.accentColor)
                                ForEach(group.names, id: \.self) { Text($0).font(.title3).foregroundStyle(.white.opacity(0.9)) }
                            }
                        }
                        if let quote = quote {
                            VStack(spacing: 4) {
                                Text("«\(quote.text)»").font(.title3.italic()).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                                Text(quote.film).font(.caption).foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(.horizontal, 30)
                        }
                        if !similar.isEmpty {
                            Text("DA VEDERE DOPO").font(.system(size: 11, weight: .bold)).tracking(3).foregroundStyle(settings.accentColor)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(similar.prefix(10), id: \.tmdbID) { item in
                                        Button { open(item) } label: {
                                            RemoteImage(urlString: item.posterURL, width: 140, placeholderSeed: item.title)
                                                .frame(width: 96, height: 144)
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        }
                                        .buttonStyle(.pressable)
                                        .accessibilityLabel(item.title)
                                    }
                                }
                                .padding(.horizontal, 24)
                            }
                        }
                        Button("Chiudi") { onClose() }.buttonStyle(PrimaryActionButtonStyle()).padding(.bottom, 40)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, proxy.size.height * 0.6)
                    .offset(y: rolled ? -proxy.size.height * 0.35 : 0)
                }
            }
            VStack {
                HStack { Spacer(); GlassIconButton(systemName: "xmark", accessibilityLabel: "Chiudi") { onClose() } }.padding()
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .transition(.opacity)
        .task {
            if settings.animationsEnabled && settings.value.appearance.kenBurns { withAnimation(.easeOut(duration: 3.5)) { rolled = true } }
            let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
            similar = (await env.metadata.richDetails(for: meta, language: language))?.similar ?? []
        }
    }

    private func open(_ item: TitleRichDetails.Similar) {
        guard !opening else { return }
        opening = true
        Task {
            defer { opening = false }
            guard let imdb = await env.metadata.imdbID(forTMDBID: item.tmdbID, metaType: meta.type) else { return }
            onOpen(MetaRoute(type: meta.type, id: imdb, preview: MetaItem(id: imdb, type: meta.type, name: item.title, poster: item.posterURL)))
        }
    }
}

// MARK: - Cinema together: chat

/// The chat of a SharePlay call: short lines to the people watching the same film, kept for the length of the call.
struct WatchChatSheet: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View { WatchChatContent(service: env.watchTogether) }
}

private struct WatchChatContent: View {
    @ObservedObject var service: WatchTogetherService
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    private var myName: String { return settings.value.content.profile.displayName ?? "Io" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if service.chat.isEmpty {
                                Text("Scrivi qualcosa a chi guarda con te. I messaggi restano solo per la durata della chiamata.")
                                    .font(.footnote).foregroundStyle(Color.aetherSecondary).padding()
                            }
                            ForEach(service.chat) { message in
                                let mine = message.sender == myName
                                VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                                    Text(message.sender).font(.caption2).foregroundStyle(Color.aetherSecondary)
                                    Text(message.text).padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(mine ? AnyShapeStyle(settings.accentColor.opacity(0.85)) : AnyShapeStyle(Color.primary.opacity(0.12)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .foregroundStyle(mine ? Color.white : Color.primary)
                                }
                                .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
                                .id(message.id)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .onChange(of: service.chat.count) { _, _ in
                        if let last = service.chat.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                HStack {
                    TextField("Scrivi un messaggio", text: $draft).textFieldStyle(.roundedBorder).submitLabel(.send).onSubmit(send)
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
            }
            .navigationTitle("Cinema insieme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        service.sendChat(draft, sender: myName)
        draft = ""
        Haptics.tap()
    }
}
