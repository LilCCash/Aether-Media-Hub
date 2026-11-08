import UIKit

/// The film's logo leaving the list of sources for the player: black comes over the screen while the logo goes to the middle, grows
/// and turns a quarter clockwise, the way the screen turns for the player. Done with Core Animation on a layer over the window: the
/// system draws it, so it stays smooth while the app is busy preparing the source.
@MainActor
enum LogoFlightAnimator {
    private static weak var cover: UIView?

    static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
    }

    /// `frame` is where the logo is now, in screen coordinates.
    static func fly(image: UIImage?, title: String, from frame: CGRect, duration: TimeInterval = 0.62) {
        guard let window = keyWindow, frame.width > 0, frame.height > 0 else { return }
        land(animated: false)
        let container = UIView(frame: window.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.isUserInteractionEnabled = true
        let backdrop = UIView(frame: container.bounds)
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.backgroundColor = .black
        backdrop.alpha = 0
        container.addSubview(backdrop)
        let picture = image ?? titleImage(title, width: frame.width)
        let logo = UIImageView(image: picture)
        logo.contentMode = .scaleAspectFit
        logo.frame = frame
        logo.layer.shadowColor = UIColor.black.cgColor
        logo.layer.shadowOpacity = 0.6
        logo.layer.shadowRadius = 10
        logo.layer.shadowOffset = .zero
        container.addSubview(logo)
        window.addSubview(container)
        cover = container

        // Sideways the logo is as wide as on the start page: up to 440 points, never more than most of the screen's height.
        let wanted = min(440, window.bounds.height * 0.62)
        let grow = min(2.4, max(1, wanted / frame.width))
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            backdrop.alpha = 1
            logo.center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
            logo.transform = CGAffineTransform(rotationAngle: .pi / 2).scaledBy(x: grow, y: grow)
        }
    }

    /// Takes the black and the logo away: faded when the list comes back, at once when the player's page is already over it.
    static func land(animated: Bool) {
        guard let view = cover else { return }
        cover = nil
        guard animated else { view.removeFromSuperview(); return }
        UIView.animate(withDuration: 0.3, animations: { view.alpha = 0 }, completion: { _ in view.removeFromSuperview() })
    }

    /// The name in big letters, for a film without a logo.
    private static func titleImage(_ title: String, width: CGFloat) -> UIImage {
        let font = UIFont.systemFont(ofSize: 28, weight: .heavy)
        let serif = font.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 28) } ?? font
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: serif, .foregroundColor: UIColor.white, .paragraphStyle: style]
        let text = NSAttributedString(string: title, attributes: attributes)
        let bounds = text.boundingRect(with: CGSize(width: max(width, 120), height: 200), options: [.usesLineFragmentOrigin], context: nil)
        let size = CGSize(width: max(width, 120), height: ceil(bounds.height) + 4)
        return UIGraphicsImageRenderer(size: size).image { _ in
            text.draw(with: CGRect(origin: .zero, size: size), options: [.usesLineFragmentOrigin], context: nil)
        }
    }
}
