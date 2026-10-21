import XCTest
import SwiftUI
import UIKit
import AetherCore
@testable import Aether

/// The TorBox cache pill of a torrent row must be as small as the "Torrent" pill beside it. A device screenshot showed a tall
/// capsule holding only a check mark (no text) next to the "Torrent" pill.
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
}
