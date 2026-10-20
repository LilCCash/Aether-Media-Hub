import XCTest
import AetherCore
@testable import Aether

/// Network layer replaced by a script: the tests of the subtitle loader never leave the process.
private final class SubtitleStubHTTP: HTTPClient, @unchecked Sendable {
    var status = 200
    var body = Data()
    var failure: Error?
    private(set) var requests: [HTTPRequest] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if let failure = failure { throw failure }
        return HTTPResponse(data: body, statusCode: status, headers: [:], url: request.url)
    }
}

/// Downloading and parsing an addon subtitle, with the failures the viewer is told about.
final class SubtitleFileLoaderTests: XCTestCase {
    private let url = URL(string: "https://subs.example/file/1")!
    private let srt = "1\n00:00:01,000 --> 00:00:03,000\nCiao\n"

    func testADownloadedSubtitleBecomesCues() async throws {
        let http = SubtitleStubHTTP()
        http.body = Data(srt.utf8)
        let cues = try await SubtitleFileLoader(http: http).load(url: url, languageHint: "ita", encodingHint: nil)
        XCTAssertEqual(cues.map { $0.text }, ["Ciao"])
        XCTAssertEqual(cues.first?.start ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(cues.first?.end ?? -1, 3, accuracy: 0.001)
    }

    func testTheRequestIsABoundedGET() async throws {
        let http = SubtitleStubHTTP()
        http.body = Data(srt.utf8)
        _ = try await SubtitleFileLoader(http: http).load(url: url, languageHint: nil, encodingHint: nil)
        XCTAssertEqual(http.requests.count, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.maxBytes, HTTPLimits.subtitle, "a subtitle can never be larger than the subtitle limit")
        XCTAssertEqual(request.purpose, .addonRequest)
    }

    func testTheCharsetAnnouncedByTheAddonIsUsed() async throws {
        let text = "1\n00:00:01,000 --> 00:00:03,000\nПривет\n"
        let data = try XCTUnwrap(text.data(using: .windowsCP1251))
        let http = SubtitleStubHTTP()
        http.body = data
        let loader = SubtitleFileLoader(http: http)
        let hint = SubtitleCatalog.encodingHint(forURL: "https://subs.example/file/1?senc=cp1251")
        XCTAssertEqual(hint, "cp1251")
        let announced = try await loader.load(url: url, languageHint: nil, encodingHint: hint)
        XCTAssertEqual(announced.first?.text, "Привет")
        let guessed = try await loader.load(url: url, languageHint: nil, encodingHint: nil)
        XCTAssertNotEqual(guessed.first?.text, "Привет", "without the announcement the default code page is used")
    }

    func testAnHTTPErrorIsReportedWithItsStatus() async {
        let http = SubtitleStubHTTP()
        http.status = 404
        do {
            _ = try await SubtitleFileLoader(http: http).load(url: url, languageHint: nil, encodingHint: nil)
            XCTFail("a 404 must not produce cues")
        } catch {
            XCTAssertEqual(error as? AddonError, AddonError.http(status: 404))
            let message = SubtitleFileLoader.message(for: error)
            XCTAssertTrue(message.hasPrefix("Sottotitoli non scaricabili"), message)
            XCTAssertTrue(message.contains("404"), message)
        }
    }

    func testAFileThatIsNotASubtitleIsReportedAsSuch() async {
        let http = SubtitleStubHTTP()
        http.body = Data("This is not a subtitle file.\n".utf8)
        do {
            _ = try await SubtitleFileLoader(http: http).load(url: url, languageHint: nil, encodingHint: nil)
            XCTFail("text without cues must not produce cues")
        } catch {
            XCTAssertEqual(error as? SubtitleError, SubtitleError.unsupportedFormat)
            XCTAssertEqual(SubtitleFileLoader.message(for: error), SubtitleError.unsupportedFormat.message)
        }
    }

    func testAnEmptyFileIsReportedAsEmpty() async {
        let http = SubtitleStubHTTP()
        do {
            _ = try await SubtitleFileLoader(http: http).load(url: url, languageHint: nil, encodingHint: nil)
            XCTFail("an empty body must not produce cues")
        } catch {
            XCTAssertEqual(error as? SubtitleError, SubtitleError.empty)
        }
    }

    func testATransportFailureIsReportedInItalian() async {
        let http = SubtitleStubHTTP()
        http.failure = AddonError.offline
        do {
            _ = try await SubtitleFileLoader(http: http).load(url: url, languageHint: nil, encodingHint: nil)
            XCTFail("an offline error must be thrown")
        } catch {
            XCTAssertEqual(SubtitleFileLoader.message(for: error), "Sottotitoli non scaricabili: Nessuna connessione a Internet.")
        }
    }
}

/// The view model's subtitle handling on its own: no stream is started, no addon is asked. Files come from disk.
@MainActor
final class PlayerSubtitleModelTests: XCTestCase {
    private func makeModel() -> PlayerViewModel {
        let env = AppEnvironment(arguments: ["-AETHER_UITEST", "-AETHER_UITEST_SESSION", UUID().uuidString, "-AETHER_UITEST_RESET"])
        let meta = MetaItem(id: "tt9000001", type: "movie", name: "Aether Fixture One")
        let stream = AddonStream(source: .url("https://cdn.example.com/film.mp4"), name: "Test")
        let request = PlayerRequest(meta: meta, video: nil, source: .stream(stream), alternatives: [])
        return PlayerViewModel(request: request, env: env)
    }

    private func writeTemporaryFile(_ text: String, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func testAnImportedSubtitleIsShownAndSurvivesTheReplacementOfTheEngine() async throws {
        let model = makeModel()
        defer { model.teardown() }
        let file = try writeTemporaryFile("1\n00:00:00,000 --> 00:01:40,000\nCiao dal file\n", name: "prova.srt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        model.importLocalSubtitle(file)
        XCTAssertEqual(model.selectedSubtitleID, "local-prova.srt")
        XCTAssertTrue(model.subtitleOptions.contains(where: { $0.id == "local-prova.srt" }), "the file is listed")
        let shown = await waitUntil {
            model.adjustSubtitleDelay(by: 0)
            return !model.activeCues.isEmpty
        }
        XCTAssertTrue(shown, "the cue at the playhead should be drawn")
        XCTAssertEqual(model.activeCues.map { $0.text }, ["Ciao dal file"])

        // The engine fallback re-creates the engine: the subtitle is drawn by the app and must stay on.
        model.engineReplaced()
        XCTAssertEqual(model.selectedSubtitleID, "local-prova.srt", "still selected after the engine was replaced")
        model.adjustSubtitleDelay(by: 0)
        XCTAssertEqual(model.activeCues.map { $0.text }, ["Ciao dal file"], "still drawn after the engine was replaced")
        XCTAssertNil(model.subtitleError)
    }

    func testTheDelayMovesTheCueWithoutTouchingTheFile() async throws {
        let model = makeModel()
        defer { model.teardown() }
        let file = try writeTemporaryFile("1\n00:00:05,000 --> 00:01:40,000\nPiù tardi\n", name: "tardi.srt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        model.importLocalSubtitle(file)
        // The playhead is at 0 s and the cue starts at 5 s: it is due only once the subtitles are brought 5 s forward.
        model.adjustSubtitleDelay(by: -5)
        XCTAssertEqual(model.subtitleDelay, -5, accuracy: 0.001)
        let due = await waitUntil {
            model.adjustSubtitleDelay(by: 0)
            return !model.activeCues.isEmpty
        }
        XCTAssertTrue(due, "an earlier delay brings the cue forward")
        XCTAssertEqual(model.activeCues.map { $0.text }, ["Più tardi"])
        model.adjustSubtitleDelay(by: 5)
        XCTAssertEqual(model.subtitleDelay, 0, accuracy: 0.001)
        XCTAssertTrue(model.activeCues.isEmpty, "back at zero the cue waits for 5 s again")
    }

    func testAFileThatIsNotASubtitleClearsTheSelectionAndSaysWhy() async throws {
        let model = makeModel()
        defer { model.teardown() }
        let file = try writeTemporaryFile("Questo file non contiene sottotitoli.\n", name: "rotto.srt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        model.importLocalSubtitle(file)
        let failed = await waitUntil { model.subtitleError != nil }
        XCTAssertTrue(failed, "the failure must be reported")
        XCTAssertEqual(model.subtitleError, SubtitleError.unsupportedFormat.message)
        XCTAssertNil(model.selectedSubtitleID, "a subtitle that failed must not look selected")
        XCTAssertTrue(model.activeCues.isEmpty)
        XCTAssertEqual(model.externalSubtitleCount(), 0)
        XCTAssertTrue(model.subtitleOptions.contains(where: { $0.id == "local-rotto.srt" }), "it stays listed to be tried again")

        // Retrying selects it again (and fails again, the file has not changed).
        model.retrySubtitle()
        XCTAssertEqual(model.selectedSubtitleID, "local-rotto.srt")
        XCTAssertNil(model.subtitleError, "the old message goes away while the new attempt runs")
        let failedAgain = await waitUntil { model.subtitleError != nil }
        XCTAssertTrue(failedAgain)
        XCTAssertNil(model.selectedSubtitleID)
    }

    func testOnlyASubtitleDrawnByTheAppCountsForARemoteReceiver() throws {
        let model = makeModel()
        defer { model.teardown() }
        XCTAssertEqual(model.externalSubtitleCount(), 0)
        let embedded = SubtitleOption(id: "embedded-1", title: "Italiano", detail: "Incorporato", language: "ita",
                                      kind: .embedded("1"), languageCode: "it")
        model.selectSubtitle(embedded)
        XCTAssertEqual(model.externalSubtitleCount(), 0, "an embedded track travels with the video")

        let file = try writeTemporaryFile("1\n00:00:00,000 --> 00:00:10,000\nCiao\n", name: "esterno.srt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        model.importLocalSubtitle(file)
        XCTAssertEqual(model.externalSubtitleCount(), 1)
        model.disableSubtitles()
        XCTAssertEqual(model.externalSubtitleCount(), 0)
    }

    func testChoicesMadeByHandAreRememberedForTheSession() {
        let model = makeModel()
        defer { model.teardown() }
        XCTAssertTrue(model.trackMemory.isEmpty)

        model.selectAudio(EngineTrack(id: "1", title: "日本語", language: "jpn", isSelected: false))
        XCTAssertEqual(model.trackMemory.audioLanguageToApply(forMeta: "tt9000001"), "ja")

        let italian = SubtitleOption(id: "embedded-1", title: "Italiano", detail: "Incorporato", language: "ita",
                                     kind: .embedded("1"), languageCode: "it")
        model.selectSubtitle(italian)
        XCTAssertEqual(model.selectedSubtitleID, "embedded-1")
        XCTAssertEqual(model.trackMemory.subtitleChoiceToApply(forMeta: "tt9000001"), .language("it"))

        model.disableSubtitles()
        XCTAssertNil(model.selectedSubtitleID)
        XCTAssertEqual(model.trackMemory.subtitleChoiceToApply(forMeta: "tt9000001"), .off)
        XCTAssertEqual(model.trackMemory.audioLanguageToApply(forMeta: "tt9000001"), "ja", "audio and subtitles are remembered separately")
    }

    func testClosingThePlayerForgetsTheChoices() {
        let model = makeModel()
        model.disableSubtitles()
        model.selectAudio(EngineTrack(id: "0", title: "Italiano", language: "ita", isSelected: false))
        XCTAssertFalse(model.trackMemory.isEmpty)
        model.teardown()
        XCTAssertTrue(model.trackMemory.isEmpty)
    }
}
