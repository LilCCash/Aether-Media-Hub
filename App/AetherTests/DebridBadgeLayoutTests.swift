import XCTest
import SwiftUI
import UIKit
import AetherCore
@testable import Aether

/// Sanity checks on the TorBox cache pill of a torrent row: it must be as small as the "Torrent" pill beside it. A device
/// screenshot showed a tall capsule holding only a check mark (no text) next to the "Torrent" pill.
/// The first three tests measure the pill alone, in a `Button`, with a bare hosting controller: they also passed against the
/// `Label` version that showed the defect, so they are NOT a reproduction. The last one measures a real `List` row (where the
/// defect was seen) and is the one that can tell the two versions apart.
@MainActor
final class DebridBadgeLayoutTests: XCTestCase {
    private let width: CGFloat = 340

    private func measure<V: View>(_ view: V) -> CGSize {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
        return host.sizeThatFits(in: CGSize(width: width, height: 1000))
    }

    private func row(_ badge: DebridCacheBadge?) -> DebridBadgeRow {
        DebridBadgeRow(appearance: DebridRowAppearance(torBoxConfigured: true, badge: badge))
    }

    func testTheCachePillIsNotTallerThanTheTorrentPill() {
        let alone = measure(row(nil))
        XCTAssertGreaterThan(alone.height, 10, "the Torrent pill itself should be measurable")
        for badge in [DebridCacheBadge.checking, .cached, .notCached] {
            let size = measure(row(badge))
            XCTAssertLessThanOrEqual(size.height, alone.height + 1, "\(badge): the pill is \(size.height) pt tall, the Torrent pill \(alone.height) pt")
        }
    }

    func testTheCachePillShowsItsTextAndNotJustTheIcon() {
        let alone = measure(row(nil))
        for badge in [DebridCacheBadge.checking, .cached, .notCached] {
            let size = measure(row(badge))
            // An icon alone would add about 30 pt; icon, gap and the words add well over 50.
            XCTAssertGreaterThan(size.width - alone.width, 50, "\(badge): the pill is only \(size.width - alone.width) pt wide")
        }
    }

    func testTheCachePillStaysSmallInsideAStreamRow() {
        func context(_ badge: DebridCacheBadge?) -> some View {
            Button(action: {}) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Backrooms 2160p")
                    row(badge)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
        }
        let without = measure(context(nil))
        for badge in [DebridCacheBadge.checking, .cached, .notCached] {
            let with = measure(context(badge))
            XCTAssertLessThanOrEqual(with.height, without.height + 1, "\(badge): the row grew from \(without.height) to \(with.height) pt")
        }
    }

    // MARK: In a List row (the context of the defect)

    private func firstCell(in view: UIView) -> UIView? {
        if view is UICollectionViewCell || view is UITableViewCell { return view }
        for sub in view.subviews {
            if let found = firstCell(in: sub) { return found }
        }
        return nil
    }

    /// The height of the first row of an inset-grouped `List` that holds the stream-row layout, in a window that is on screen.
    private func listRowHeight(badge: DebridCacheBadge?) -> CGFloat? {
        let content = List {
            Section {
                Button(action: {}) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Backrooms 2160p").font(.system(.subheadline, design: .rounded).weight(.semibold))
                        row(badge)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
        .listStyle(.insetGrouped)
        let host = UIHostingController(rootView: content)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var cell: UIView?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.view.layoutIfNeeded()
            cell = firstCell(in: host.view)
            if cell != nil { break }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.view.layoutIfNeeded()
        return cell?.frame.height
    }

    func testTheCachePillDoesNotMakeAListRowTaller() throws {
        let without = try XCTUnwrap(listRowHeight(badge: nil), "the List row did not appear")
        for badge in [DebridCacheBadge.checking, .cached, .notCached] {
            let with = try XCTUnwrap(listRowHeight(badge: badge), "the List row did not appear")
            XCTAssertEqual(with, without, accuracy: 3, "\(badge): the row is \(with) pt high with the pill and \(without) pt without it")
        }
    }
}
