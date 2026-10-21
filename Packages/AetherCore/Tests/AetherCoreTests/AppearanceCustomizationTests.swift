import XCTest
@testable import AetherCore

final class AppearanceCustomizationTests: XCTestCase {
    private func decode(_ json: String) throws -> AppearanceSettings {
        return try JSONDecoder.aether().decode(AppearanceSettings.self, from: Data(json.utf8))
    }

    // MARK: Defaults

    func testDefaultsKeepTheOneDotZeroLook() {
        let a = AppearanceSettings()
        XCTAssertEqual(a.heroStyle, .card)
        XCTAssertTrue(a.heroAutoScroll)
        XCTAssertEqual(a.palette, .aether)
        XCTAssertEqual(a.backdrop, .aurora)
        XCTAssertEqual(a.cardChrome, .standard)
        XCTAssertEqual(a.cornerStyle, .standard)
        XCTAssertEqual(a.cornerStyle.radius, 14, "the radius posters have always had")
        XCTAssertEqual(a.titleFont, .rounded)
        XCTAssertFalse(a.greetingEnabled)
        XCTAssertTrue(a.unlockedSecrets.isEmpty)
        XCTAssertTrue(a.homeSections.allSatisfy { $0.style == nil && $0.size == nil })
    }

    func testDefaultStylesAreTheCardsOfOneDotZero() {
        XCTAssertEqual(HomeSectionConfig(id: HomeSectionConfig.continueWatching).effectiveStyle, .landscape)
        XCTAssertEqual(HomeSectionConfig(id: HomeSectionConfig.nextUp).effectiveStyle, .compact)
        XCTAssertEqual(HomeSectionConfig(id: HomeSectionConfig.watchlist).effectiveStyle, .poster)
        XCTAssertEqual(HomeSectionConfig(id: HomeSectionConfig.catalogs).effectiveStyle, .poster)
        XCTAssertNil(HomeSectionConfig(id: HomeSectionConfig.hero).effectiveStyle, "the hero has its own style")
        XCTAssertEqual(PosterSize.medium.landscapeWidth, 240, "the width of the Continue Watching card in 1.0")
        XCTAssertEqual(PosterSize.medium.rowWidth, 128)
    }

    /// In 1.0 the Continue Watching and Next Up cards had a fixed width (240 pt): "Auto" must not make them follow a general
    /// poster size the viewer chose for something else.
    func testAutoSizeKeepsContinueWatchingAndNextUpAtMedium() {
        for general in PosterSize.allCases {
            XCTAssertEqual(HomeSectionConfig(id: HomeSectionConfig.continueWatching).effectiveSize(general: general), .medium)
            XCTAssertEqual(HomeSectionConfig(id: HomeSectionConfig.nextUp).effectiveSize(general: general), .medium)
            XCTAssertEqual(HomeSectionConfig(id: HomeSectionConfig.watchlist).effectiveSize(general: general), general)
            XCTAssertEqual(HomeSectionConfig(id: HomeSectionConfig.catalogs).effectiveSize(general: general), general)
        }
    }

    func testAChosenSizeWinsEverywhere() {
        XCTAssertEqual(HomeSectionConfig(id: HomeSectionConfig.continueWatching, size: .large).effectiveSize(general: .small), .large)
        XCTAssertEqual(HomeSectionConfig(id: HomeSectionConfig.catalogs, size: .small).effectiveSize(general: .large), .small)
    }

    func testSizesGrowWithTheChoice() {
        XCTAssertLessThan(PosterSize.small.landscapeWidth, PosterSize.medium.landscapeWidth)
        XCTAssertLessThan(PosterSize.medium.landscapeWidth, PosterSize.large.landscapeWidth)
    }

    // MARK: Old files

    /// Settings stored by 1.0: sections without `style` and `size`. A synthesized decoder would drop all of them and the
    /// viewer's order and hidden sections would reset without a word.
    func testSectionsStoredByOneDotZeroAreKept() throws {
        let a = try decode("""
        {"theme":"dark","homeSections":[{"id":"catalogs","isVisible":false},{"id":"hero","isVisible":true},{"id":"watchlist","isVisible":true},{"id":"continue","isVisible":false},{"id":"nextUp","isVisible":true}]}
        """)
        XCTAssertEqual(a.homeSections.map { $0.id }, ["catalogs", "hero", "watchlist", "continue", "nextUp"])
        XCTAssertEqual(a.homeSections.map { $0.isVisible }, [false, true, true, false, true])
        XCTAssertEqual(a.theme, .dark)
    }

    func testASectionWithoutVisibilityIsVisible() throws {
        let a = try decode(#"{"homeSections":[{"id":"nextUp"}]}"#)
        XCTAssertEqual(a.homeSections.first?.id, "nextUp")
        XCTAssertEqual(a.homeSections.first?.isVisible, true)
    }

    func testAnUnknownStyleOrSizeFallsBackWithoutLosingTheSection() throws {
        let a = try decode(#"{"homeSections":[{"id":"watchlist","isVisible":false,"style":"holographic","size":"gigantic"}]}"#)
        let section = try XCTUnwrap(a.homeSections.first)
        XCTAssertEqual(section.id, "watchlist")
        XCTAssertFalse(section.isVisible)
        XCTAssertNil(section.style)
        XCTAssertNil(section.size)
    }

    func testAStyleASectionDoesNotOfferIsDropped() throws {
        let a = try decode(#"{"homeSections":[{"id":"watchlist","style":"compact"},{"id":"continue","style":"poster"},{"id":"hero","style":"landscape"}]}"#)
        XCTAssertNil(a.section("watchlist").style, "the compact card is only for the next-episode section")
        XCTAssertEqual(a.section("continue").style, .poster)
        XCTAssertNil(a.section("hero").style)
        XCTAssertEqual(HomeSectionConfig(id: "watchlist", style: .compact).effectiveStyle, .poster, "and it is never drawn")
    }

    func testUnknownAppearanceValuesFallBackToTheDefault() throws {
        let a = try decode("""
        {"heroStyle":"cinemascope","palette":"vaporwave","backdrop":3,"cardChrome":null,"cornerStyle":"triangle","titleFont":"comic","greetingEnabled":"yes","unlockedSecrets":"popcorn"}
        """)
        XCTAssertEqual(a, AppearanceSettings())
    }

    func testValidValuesSurviveNextToInvalidOnes() throws {
        let a = try decode(#"{"heroStyle":"fullBleed","palette":"ocean","backdrop":"flow","cardChrome":"nonsense","cornerStyle":"bubble","titleFont":"serif"}"#)
        XCTAssertEqual(a.heroStyle, .fullBleed)
        XCTAssertEqual(a.palette, .ocean)
        XCTAssertEqual(a.backdrop, .flow)
        XCTAssertEqual(a.cardChrome, .standard)
        XCTAssertEqual(a.cornerStyle, .bubble)
        XCTAssertEqual(a.titleFont, .serif)
    }

    func testEveryChoiceRoundTrips() throws {
        var settings = AppSettings()
        settings.appearance.heroStyle = .fullBleed
        settings.appearance.heroAutoScroll = false
        settings.appearance.palette = .candy
        settings.appearance.backdrop = .spotlight
        settings.appearance.cardChrome = .glow
        settings.appearance.cornerStyle = .rounded
        settings.appearance.titleFont = .mono
        settings.appearance.greetingEnabled = true
        settings.appearance.greetingName = "Giulia"
        settings.appearance.homeSections[3].style = .landscape
        settings.appearance.homeSections[3].size = .large
        settings.appearance.homeSections[2].style = .poster
        let data = try JSONEncoder.aether().encode(settings)
        let decoded = try JSONDecoder.aether().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testAllCasesHaveTitles() {
        XCTAssertTrue(HomeCardStyle.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(HeroStyle.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(AppPalette.allCases.allSatisfy { !$0.title.isEmpty && !$0.emoji.isEmpty })
        XCTAssertTrue(BackdropStyle.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(CardChrome.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(CornerStyle.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(TitleFont.allCases.allSatisfy { !$0.title.isEmpty })
    }

    func testCornerRadiiGrowWithTheChoice() {
        let radii = [CornerStyle.sharp, .standard, .rounded, .bubble].map { $0.radius }
        XCTAssertEqual(radii, radii.sorted())
        XCTAssertEqual(Set(radii).count, 4)
    }

    // MARK: Secrets

    func testTheSecretPaletteIsLockedUntilFound() throws {
        let locked = try decode(#"{"palette":"popcorn"}"#)
        XCTAssertEqual(locked.palette, .aether, "a hand-edited file cannot show a locked palette")
        let unlocked = try decode(#"{"palette":"popcorn","unlockedSecrets":["popcorn"]}"#)
        XCTAssertEqual(unlocked.palette, .popcorn)
        XCTAssertTrue(unlocked.isUnlocked(.popcorn))
        XCTAssertFalse(AppearanceSettings().isAvailable(.popcorn))
        XCTAssertTrue(AppearanceSettings().isAvailable(.sunset))
    }

    func testUnlockingWorksOnceAndPersists() throws {
        var a = AppearanceSettings()
        XCTAssertTrue(a.unlock(.popcorn))
        XCTAssertFalse(a.unlock(.popcorn), "the second time reports nothing new")
        XCTAssertEqual(a.unlockedSecrets, ["popcorn"])
        let data = try JSONEncoder.aether().encode(a)
        let decoded = try JSONDecoder.aether().decode(AppearanceSettings.self, from: data)
        XCTAssertTrue(decoded.isUnlocked(.popcorn))
    }

    func testSecretIdsFromANewerBuildAndDuplicatesAreHandled() throws {
        let a = try decode(#"{"unlockedSecrets":["popcorn","popcorn","something-new",7]}"#)
        XCTAssertEqual(a.unlockedSecrets, ["popcorn", "something-new", "7"])
    }

    func testOnlyTheSecretPaletteNeedsASecret() {
        for palette in AppPalette.allCases {
            XCTAssertEqual(palette.requiredSecret != nil, palette == .popcorn)
        }
    }

    // MARK: Order

    private func ids(_ sections: [HomeSectionConfig]) -> [String] { return sections.map { $0.id } }

    func testMovingASectionDownAndUp() {
        let start = HomeSectionConfig.defaultOrder
        let down = HomeSectionOrdering.moved(start, id: "hero", by: 1)
        XCTAssertEqual(ids(down), ["continue", "hero", "nextUp", "watchlist", "catalogs"])
        let up = HomeSectionOrdering.moved(down, id: "hero", by: -1)
        XCTAssertEqual(ids(up), ids(start))
    }

    func testMovingPastTheEdgesChangesNothing() {
        let start = HomeSectionConfig.defaultOrder
        XCTAssertEqual(HomeSectionOrdering.moved(start, id: "hero", by: -1), start)
        XCTAssertEqual(HomeSectionOrdering.moved(start, id: "catalogs", by: 1), start)
        XCTAssertEqual(HomeSectionOrdering.moved(start, id: "nope", by: 1), start)
        XCTAssertFalse(HomeSectionOrdering.canMove(start, id: "hero", by: -1))
        XCTAssertFalse(HomeSectionOrdering.canMove(start, id: "catalogs", by: 1))
        XCTAssertTrue(HomeSectionOrdering.canMove(start, id: "hero", by: 1))
        XCTAssertFalse(HomeSectionOrdering.canMove(start, id: "nope", by: 1))
    }

    func testMovingKeepsEachSectionsChoices() {
        var start = HomeSectionConfig.defaultOrder
        start[3].style = .landscape
        start[3].size = .large
        start[3].isVisible = false
        let moved = HomeSectionOrdering.moved(start, id: "watchlist", by: -3)
        XCTAssertEqual(moved.first?.id, "watchlist")
        XCTAssertEqual(moved.first?.style, .landscape)
        XCTAssertEqual(moved.first?.size, .large)
        XCTAssertEqual(moved.first?.isVisible, false)
        XCTAssertEqual(Set(ids(moved)), Set(ids(start)))
    }

    func testAJumpFurtherThanTheListIsClamped() {
        let moved = HomeSectionOrdering.moved(HomeSectionConfig.defaultOrder, id: "continue", by: 99)
        XCTAssertEqual(moved.last?.id, "continue")
    }

    // MARK: Greeting

    func testGreetingFollowsTheHour() {
        XCTAssertEqual(Greeting.text(hour: 4, name: ""), "Ancora sveglio?")
        XCTAssertEqual(Greeting.text(hour: 5, name: ""), "Buongiorno")
        XCTAssertEqual(Greeting.text(hour: 11, name: ""), "Buongiorno")
        XCTAssertEqual(Greeting.text(hour: 12, name: ""), "Buon pomeriggio")
        XCTAssertEqual(Greeting.text(hour: 17, name: ""), "Buon pomeriggio")
        XCTAssertEqual(Greeting.text(hour: 18, name: ""), "Buonasera")
        XCTAssertEqual(Greeting.text(hour: 23, name: ""), "Buonasera")
        XCTAssertEqual(Greeting.text(hour: 0, name: ""), "Ancora sveglio?")
    }

    func testGreetingUsesTheName() {
        XCTAssertEqual(Greeting.text(hour: 9, name: "Giulia"), "Buongiorno, Giulia")
        XCTAssertEqual(Greeting.text(hour: 2, name: "Giulia"), "Ancora sveglio, Giulia?")
        XCTAssertEqual(Greeting.text(hour: 20, name: "  Gian   Marco \n"), "Buonasera, Gian Marco")
    }

    func testTheNameIsBoundedAndSingleLine() {
        let long = String(repeating: "a", count: 80)
        XCTAssertEqual(Greeting.sanitizedName(long).count, Greeting.maxNameLength)
        XCTAssertEqual(Greeting.sanitizedName("Ann\nBob\r\nCy"), "Ann Bob Cy")
        XCTAssertEqual(Greeting.sanitizedName("   "), "")
    }

    func testAStoredNameIsSanitizedOnLoad() throws {
        let a = try decode(#"{"greetingName":"  Mario\nRossi  ","greetingEnabled":true}"#)
        XCTAssertEqual(a.greetingName, "Mario Rossi")
        XCTAssertTrue(a.greetingEnabled)
    }

    // MARK: Contrast

    func testHexParsing() throws {
        let white = try XCTUnwrap(ContrastRatio.rgb("#FFFFFF"))
        let black = try XCTUnwrap(ContrastRatio.rgb("000000"))
        XCTAssertEqual(ContrastRatio.ratio(white, black), 21, accuracy: 0.01)
        XCTAssertNil(ContrastRatio.rgb("#FFF"))
        XCTAssertNil(ContrastRatio.rgb("zzzzzz"))
    }

    /// The washes are only drawn behind the content, at most `maxWashOpacity`. Text is the system label colour, so what has
    /// to hold is: label over background-plus-wash stays at 4.5:1 or better in both schemes, also for the 72 % secondary text.
    func testEveryPaletteKeepsTextReadable() throws {
        // The two page backgrounds of the app: light is UIColor.systemGroupedBackground, dark is the deep blue of AetherBackdrop.
        let light = try XCTUnwrap(ContrastRatio.rgb("#F2F2F7"))
        let dark = try XCTUnwrap(ContrastRatio.rgb("#050814"))
        let black = try XCTUnwrap(ContrastRatio.rgb("#000000"))
        let white = try XCTUnwrap(ContrastRatio.rgb("#FFFFFF"))
        for palette in AppPalette.allCases {
            guard let washes = palette.washes else { continue }
            for hex in [washes.primary, washes.secondary] {
                let wash = try XCTUnwrap(ContrastRatio.rgb(hex), "\(palette): bad colour \(hex)")
                for (background, label, name) in [(light, black, "light"), (dark, white, "dark")] {
                    let page = ContrastRatio.blend(wash, opacity: AppPalette.maxWashOpacity, over: background)
                    XCTAssertGreaterThanOrEqual(ContrastRatio.ratio(label, page), 7, "\(palette) \(hex) \(name): primary text")
                    let secondary = ContrastRatio.blend(label, opacity: 0.72, over: page)
                    XCTAssertGreaterThanOrEqual(ContrastRatio.ratio(secondary, page), 4.5, "\(palette) \(hex) \(name): secondary text")
                }
            }
        }
    }

    func testPaletteColoursAreValidAndDistinct() {
        for palette in AppPalette.allCases {
            guard let washes = palette.washes else { continue }
            XCTAssertNotNil(ContrastRatio.rgb(washes.primary), "\(palette)")
            XCTAssertNotNil(ContrastRatio.rgb(washes.secondary), "\(palette)")
            XCTAssertNotEqual(washes.primary, washes.secondary, "\(palette)")
        }
        let primaries = AppPalette.allCases.compactMap { $0.washes?.primary }
        XCTAssertEqual(Set(primaries).count, primaries.count, "two palettes look alike")
        XCTAssertNil(AppPalette.aether.washes, "the default follows the accent colour")
    }
}
