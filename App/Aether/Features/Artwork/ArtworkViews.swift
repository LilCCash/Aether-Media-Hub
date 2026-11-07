import SwiftUI
import Photos
import AetherCore

// MARK: - Saving to Photos

enum PhotoSaver {
    /// Adds the picture to the Photos library (the app only asks for permission to add, never to read).
    static func save(_ image: UIImage) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { ok, _ in continuation.resume(returning: ok) })
        }
    }
}

/// Thumbnail address for a picture that is stored at the biggest size (`…/original/…` on TMDB).
func artworkThumbnail(_ url: String) -> String {
    return url.replacingOccurrences(of: "/original/", with: "/w500/")
}

// MARK: - Artwork Explorer

/// Every poster, backdrop and logo TMDB has for a title. From here a picture can become the poster, a wallpaper, or the ambient mode.
struct ArtworkExplorerView: View {
    let meta: MetaItem
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var artwork = TitleArtwork()
    @State private var loading = true
    @State private var kind: Kind = .backdrops
    @State private var opened: Picked?
    @State private var ambient = false

    enum Kind: String, CaseIterable { case posters = "Locandine", backdrops = "Sfondi", logos = "Loghi" }
    struct Picked: Identifiable { let url: String; let kind: Kind; var id: String { url } }

    private var urls: [String] {
        switch kind {
        case .posters: return artwork.posters
        case .backdrops: return artwork.backdrops
        case .logos: return artwork.logos
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AetherBackdrop()
                ScrollView {
                    VStack(spacing: 14) {
                        Picker("Tipo", selection: $kind) {
                            ForEach(Kind.allCases, id: \.self) { Text("\($0.rawValue) \(count($0))").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if loading {
                            ProgressView().padding(40)
                        } else if urls.isEmpty {
                            Text(artwork.isEmpty ? "TMDB non ha immagini per questo titolo, oppure manca la chiave TMDB (Impostazioni ▸ Servizi e chiavi)."
                                 : "Nessuna immagine di questo tipo.")
                                .multilineTextAlignment(.center).foregroundStyle(Color.aetherSecondary).padding(24)
                        } else {
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(urls, id: \.self) { url in
                                    Button { opened = Picked(url: url, kind: kind); Haptics.tap() } label: { cell(url) }
                                        .buttonStyle(.pressable)
                                }
                            }
                        }
                    }
                    .padding(Theme.pageMargin)
                }
            }
            .navigationTitle(meta.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { ambient = true } label: { Label("Modalità ambiente", systemImage: "sparkles.tv") }
                        .disabled(artwork.backdrops.isEmpty && meta.background == nil)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() }.fontWeight(.semibold) }
            }
            .fullScreenCover(item: $opened) { picked in ArtworkDetailView(meta: meta, url: picked.url, isPoster: picked.kind == .posters, isLogo: picked.kind == .logos) }
            .fullScreenCover(isPresented: $ambient) { AmbientModeView(meta: meta, backdrops: artwork.backdrops) }
            .task {
                let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
                artwork = await env.metadata.artwork(for: meta, language: language)
                if artwork.backdrops.isEmpty { kind = artwork.posters.isEmpty ? .logos : .posters }
                loading = false
            }
        }
    }

    private func count(_ kind: Kind) -> String {
        let n: Int
        switch kind {
        case .posters: n = artwork.posters.count
        case .backdrops: n = artwork.backdrops.count
        case .logos: n = artwork.logos.count
        }
        return loading || n == 0 ? "" : "(\(n))"
    }

    private var columns: [GridItem] {
        switch kind {
        case .posters: return [GridItem(.adaptive(minimum: 100), spacing: 10)]
        case .backdrops: return [GridItem(.adaptive(minimum: 160), spacing: 10)]
        case .logos: return [GridItem(.adaptive(minimum: 130), spacing: 10)]
        }
    }

    @ViewBuilder
    private func cell(_ url: String) -> some View {
        switch kind {
        case .posters:
            RemoteImage(urlString: artworkThumbnail(url), width: 120, placeholderSeed: meta.name)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .backdrops:
            RemoteImage(urlString: artworkThumbnail(url), width: 200, placeholderSeed: meta.name)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .logos:
            RemoteImage(urlString: artworkThumbnail(url).replacingOccurrences(of: "/w500/", with: "/w300/"), width: 140, contentMode: .fit, placeholderSeed: meta.name)
                .frame(height: 70)
                .padding(8)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - One picture

struct ArtworkDetailView: View {
    let meta: MetaItem
    let url: String
    let isPoster: Bool
    let isLogo: Bool
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var overrides = PosterOverrides.shared
    @Environment(\.imageLoader) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var note: String?
    @State private var wallpaper = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = image {
                Image(uiImage: image).resizable().scaledToFit().ignoresSafeArea(edges: isLogo ? [] : .all)
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    GlassIconButton(systemName: "xmark", accessibilityLabel: "Chiudi") { dismiss() }
                    Spacer()
                }
                .padding()
                Spacer()
                if let note = note { Text(note).font(.footnote.weight(.semibold)).padding(8).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 6) }
                HStack(spacing: 10) {
                    if !isLogo {
                        Button { wallpaper = true } label: { Label("Sfondo iPhone", systemImage: "iphone") }
                            .buttonStyle(PrimaryActionButtonStyle())
                    }
                    if isPoster {
                        Button { overrides.set(url, for: meta.id); note = "Locandina impostata."; Haptics.success() } label: { Label("Usa come locandina", systemImage: "photo") }
                            .buttonStyle(SecondaryActionButtonStyle())
                    }
                    if isPoster, overrides.url(for: meta.id) != nil {
                        Button { overrides.set(nil, for: meta.id); note = "Locandina originale ripristinata." } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .accessibilityLabel("Locandina originale")
                    }
                    Button { save() } label: { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .accessibilityLabel("Salva nelle Foto")
                    if let image = image {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview(meta.name, image: Image(uiImage: image))) { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(SecondaryActionButtonStyle())
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $wallpaper) {
            if let image = image { WallpaperEditorView(meta: meta, source: image) }
        }
        .task {
            guard let loader = loader, let target = URL(string: url) else { return }
            image = await loader.image(for: target, maxPixel: 4096)
        }
    }

    private func save() {
        guard let image = image else { return }
        Task {
            let ok = await PhotoSaver.save(image)
            note = ok ? "Salvata nelle Foto." : "Non posso salvare: consenti l'aggiunta di foto ad Aether nelle Impostazioni di iOS."
            if ok { Haptics.success() }
        }
    }
}

// MARK: - Wallpapers

/// Fits a picture to the iPhone screen: drag and pinch to frame it, a lock-screen preview with the clock, dimming and blur, and the result
/// saved to Photos at the real resolution of the phone (then Photos ▸ Use as wallpaper).
struct WallpaperEditorView: View {
    let meta: MetaItem
    let source: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    /// The framing, as a fraction of the picture's size, so that the preview and the export (a bigger drawing) agree.
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var previewSize = CGSize(width: 300, height: 650)
    @State private var lockPreview = true
    @State private var dim: Double = 0.15
    @State private var blur: Double = 0
    @State private var note: String?
    @State private var exported: UIImage?

    private var screenSize: CGSize { UIScreen.main.bounds.size }
    private var aspect: CGFloat { screenSize.width / max(screenSize.height, 1) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Chiudi") { dismiss() }
                Spacer()
                Text("Sfondo per iPhone").font(.headline)
                Spacer()
                Button("Salva") { save() }.fontWeight(.semibold)
            }
            .padding(.horizontal)
            GeometryReader { proxy in
                let height = min(proxy.size.height, proxy.size.width / aspect)
                let size = CGSize(width: height * aspect, height: height)
                frame(size: size, withClock: lockPreview)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { previewSize = size }
                    .onChange(of: proxy.size) { _, _ in previewSize = size }
                    .gesture(drag.simultaneously(with: pinch))
            }
            Picker("Anteprima", selection: $lockPreview) {
                Text("Schermata di blocco").tag(true)
                Text("Schermata Home").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            VStack(spacing: 6) {
                HStack { Text("Scurisci").font(.caption); Slider(value: $dim, in: 0...0.7) }
                HStack { Text("Sfoca").font(.caption).frame(width: 44, alignment: .leading); Slider(value: $blur, in: 0...30) }
            }
            .padding(.horizontal)
            if let note = note { Text(note).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
            HStack {
                Text("Trascina e pizzica per inquadrare. Salva nelle Foto, poi Foto ▸ Usa come sfondo.").font(.caption).foregroundStyle(.secondary)
                if let exported = exported {
                    ShareLink(item: Image(uiImage: exported), preview: SharePreview(meta.name, image: Image(uiImage: exported))) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged {
                offset = CGSize(width: baseOffset.width + $0.translation.width / max(previewSize.width, 1),
                                height: baseOffset.height + $0.translation.height / max(previewSize.height, 1))
            }
            .onEnded { _ in baseOffset = offset }
    }

    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { scale = min(5, max(1, baseScale * $0)) }
            .onEnded { _ in baseScale = scale }
    }

    /// The picture as it is framed in a rectangle of this size (the preview and the export draw the same thing).
    @ViewBuilder
    private func frame(size: CGSize, withClock: Bool) -> some View {
        ZStack {
            Color.black
            Image(uiImage: source)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .offset(x: offset.width * size.width, y: offset.height * size.height)
                .blur(radius: blur * size.height / 800)
                .clipped()
            Color.black.opacity(dim)
            if withClock {
                VStack(spacing: 2) {
                    Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide)).font(.system(size: size.height * 0.022, weight: .semibold))
                    Text(Date(), format: .dateTime.hour().minute()).font(.system(size: size.height * 0.1, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, size.height * 0.1)
            }
        }
    }

    private func save() {
        let pixels = CGSize(width: UIScreen.main.nativeBounds.width, height: UIScreen.main.nativeBounds.height)
        let renderer = ImageRenderer(content: frame(size: pixels, withClock: false).frame(width: pixels.width, height: pixels.height))
        renderer.scale = 1
        guard let image = renderer.uiImage else { note = "Non riesco a creare l'immagine."; return }
        exported = image
        Task {
            let ok = await PhotoSaver.save(image)
            note = ok ? "Salvato nelle Foto (\(Int(pixels.width))×\(Int(pixels.height))). Apri Foto ▸ Condividi ▸ Usa come sfondo." : "Non posso salvare: consenti l'aggiunta di foto ad Aether nelle Impostazioni di iOS."
            if ok { Haptics.success() }
        }
    }
}

// MARK: - Ambient mode

/// A slow show for a lit screen on a shelf: the title's pictures drift and cross-fade, with its name, a line from the cast and a quote.
struct AmbientModeView: View {
    let meta: MetaItem
    let backdrops: [String]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.aetherStyle) private var style
    @State private var index = 0
    @State private var drifting = false
    @State private var lineIndex = 0
    @State private var showHint = true

    private var pictures: [String] {
        let list = backdrops.isEmpty ? [meta.background ?? meta.poster].compactMap { $0 } : backdrops
        return Array(list.prefix(12))
    }

    private var lines: [String] {
        var result: [String] = []
        if !meta.cast.isEmpty { result.append("Con " + meta.cast.prefix(3).joined(separator: ", ")) }
        if !meta.directors.isEmpty { result.append("Regia di " + meta.directors.prefix(2).joined(separator: ", ")) }
        if let year = meta.releaseInfo { result.append(year) }
        if let quote = Quotes.all.randomElement() { result.append("«\(quote.text)» — \(quote.film)") }
        return result
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ForEach(Array(pictures.enumerated()), id: \.offset) { position, url in
                if position == index {
                    RemoteImage(urlString: url.replacingOccurrences(of: "/original/", with: "/w1280/"), width: 1280, placeholderSeed: meta.name)
                        .ignoresSafeArea()
                        .scaleEffect(drifting ? 1.12 : 1.0)
                        .offset(x: drifting ? -14 : 14, y: drifting ? -8 : 8)
                        .transition(.opacity)
                        .id(position)
                }
            }
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                Text(meta.name).font(.aetherTitle(34)).foregroundStyle(.white).shadow(radius: 8)
                if !lines.isEmpty {
                    Text(lines[lineIndex % lines.count]).font(.title3).foregroundStyle(.white.opacity(0.85))
                        .id(lineIndex).transition(.opacity)
                }
                if showHint { Text("Tocca per uscire").font(.caption).foregroundStyle(.white.opacity(0.5)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if style.kenBurns { withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { drifting = true } }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation { showHint = false }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 2.0)) {
                    if pictures.count > 1 { index = (index + 1) % pictures.count }
                    lineIndex += 1
                }
            }
        }
    }
}
