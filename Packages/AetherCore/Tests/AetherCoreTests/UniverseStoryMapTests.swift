import XCTest
@testable import AetherCore

final class UniverseStoryMapTests: XCTestCase {
    private func map(_ id: String, _ order: UniverseOrder = .release) throws -> UniverseStoryMap {
        let universe = try XCTUnwrap(UniverseCatalog.universe(id: id))
        return UniverseStoryMap.build(universe, order: order)
    }

    private func id(_ map: UniverseStoryMap, _ name: String) throws -> String {
        return try XCTUnwrap(map.nodes.first { $0.entry.name == name }?.entry.id, name)
    }

    func testEveryTitleOfEveryUniverseIsOnTheMapOnce() throws {
        for universe in UniverseCatalog.all {
            for order in [UniverseOrder.release, .chronological] {
                let built = UniverseStoryMap.build(universe, order: order)
                XCTAssertEqual(built.nodes.count, universe.entries.count, universe.id)
                XCTAssertEqual(Set(built.nodes.map { $0.id }).count, universe.entries.count, universe.id)
                XCTAssertEqual(built.lanes.map { $0.entries.count }.reduce(0, +), universe.entries.count, universe.id)
                let ids = Set(built.nodes.map { $0.id })
                for link in built.links {
                    XCTAssertTrue(ids.contains(link.from) && ids.contains(link.to), "\(universe.id): \(link)")
                    let from = try XCTUnwrap(built.node(link.from)), to = try XCTUnwrap(built.node(link.to))
                    XCTAssertLessThan(from.column, to.column, "\(universe.id): a line goes left to right \(from.entry.name) → \(to.entry.name)")
                    XCTAssertLessThan(from.slot, to.slot, "\(universe.id): drawn left to right \(from.entry.name) → \(to.entry.name)")
                }
                // Places never go back, and the map is narrower than one title per column when stories run side by side.
                let bySlot = built.nodes.sorted { $0.column < $1.column }.map { $0.slot }
                XCTAssertEqual(bySlot, bySlot.sorted(), universe.id)
                XCTAssertLessThanOrEqual(built.slotCount, universe.entries.count, universe.id)
                for lane in built.lanes {
                    let slots = lane.entries.compactMap { entry in built.node(entry.id)?.slot }
                    XCTAssertEqual(Set(slots).count, slots.count, "\(universe.id): two titles of one line in one place")
                }
                // Columns follow the chosen order.
                XCTAssertEqual(built.nodes.sorted { $0.column < $1.column }.map { $0.id }, universe.ordered(order).map { $0.id }, universe.id)
            }
        }
    }

    func testTheStorylinesOfTheBigUniversesCoverEveryTitle() throws {
        for id in ["mcu", "starwars", "bond", "spiderman", "hp", "lotr", "alien", "monsterverse"] {
            let built = try map(id)
            XCTAssertFalse(built.lanes.contains { $0.name == "Altri titoli" }, "\(id): \(built.lanes.first { $0.name == "Altri titoli" }?.entries.map { $0.name } ?? [])")
        }
    }

    func testTheMCULinesMeetInTheAvengersFilms() throws {
        let mcu = try map("mcu")
        XCTAssertEqual(mcu.lanes.first?.name, "Avengers", "the line where the others meet is on top")
        XCTAssertTrue(mcu.links.contains(.init(from: try id(mcu, "Iron Man"), to: try id(mcu, "Iron Man 2"), kind: .sequel)))
        let endgame = try id(mcu, "Avengers: Endgame")
        XCTAssertTrue(mcu.links.contains(.init(from: try id(mcu, "Captain Marvel"), to: endgame, kind: .crossover)))
        XCTAssertTrue(mcu.links.contains(.init(from: try id(mcu, "Avengers: Infinity War"), to: endgame, kind: .sequel)))
        XCTAssertTrue(mcu.links.contains(.init(from: endgame, to: try id(mcu, "WandaVision"), kind: .crossover)))
        let thor = try XCTUnwrap(mcu.node(try id(mcu, "Thor")))
        let loki = try XCTUnwrap(mcu.node(try id(mcu, "Loki")))
        XCTAssertEqual(thor.lane, loki.lane)
        XCTAssertEqual(mcu.lanes[thor.lane].name, "Thor e Loki")
    }

    func testBondsActorsFollowOneAnother() throws {
        let bond = try map("bond")
        XCTAssertEqual(bond.lanes.map { $0.name }, ["Sean Connery", "George Lazenby", "Roger Moore", "Timothy Dalton", "Pierce Brosnan", "Daniel Craig"])
        XCTAssertTrue(bond.links.contains(.init(from: try id(bond, "You Only Live Twice"), to: try id(bond, "On Her Majesty's Secret Service"), kind: .crossover)))
    }

    func testAnUniverseWithoutStorylinesHasFilmsAndSeries() {
        let plain = UniverseDefinition(id: "test", name: "Test", summary: "", hero: "tt1",
                                       entries: [("tt1", "Uno", 2000, false), ("tt2", "Due", 2002, false), ("tt3", "Serie", 2004, true)],
                                       chronological: nil, chronologicalNote: nil)
        let built = UniverseStoryMap.build(plain, order: .release)
        XCTAssertEqual(built.lanes.map { $0.name }, ["Film", "Serie"])
        XCTAssertEqual(built.links, [.init(from: "tt1", to: "tt2", kind: .sequel)])
    }
}
