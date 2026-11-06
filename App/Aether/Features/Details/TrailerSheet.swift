import SwiftUI
import WebKit
import AetherCore

/// A trailer to show inside the app.
struct TrailerRequest: Identifiable {
    let url: URL
    var id: String { return url.absoluteString }
}

/// The trailer played in the app (YouTube's embedded player); if the video cannot be embedded, a button opens it on YouTube.
struct TrailerSheet: View {
    let request: TrailerRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let id = YouTubeLink.id(from: request.url) {
                    YouTubeEmbed(videoID: id).ignoresSafeArea(edges: .bottom)
                } else {
                    Text("Trailer non disponibile nell'app").foregroundStyle(.white)
                }
            }
            .navigationTitle("Trailer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Chiudi") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { openURL(request.url) } label: { Label("Apri su YouTube", systemImage: "arrow.up.right.square") }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct YouTubeEmbed: UIViewRepresentable {
    let videoID: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        let html = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;background:#000;height:100%}iframe{border:0;width:100%;height:100%}</style></head>
        <body><iframe src="https://www.youtube.com/embed/\(videoID)?playsinline=1&autoplay=1&rel=0&modestbranding=1" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe></body></html>
        """
        view.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
