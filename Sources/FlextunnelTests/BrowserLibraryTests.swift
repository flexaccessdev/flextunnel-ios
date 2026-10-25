import XCTest
@testable import Flextunnel

@MainActor
final class BrowserLibraryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserLibraryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLibrary() -> BrowserLibrary {
        BrowserLibrary(directory: directory)
    }

    // MARK: - Bookmarks

    func testAddBookmarkIsNewestFirstAndRefusesDuplicates() {
        let library = makeLibrary()
        library.addBookmark(name: "A", url: url("a"))
        library.addBookmark(name: "B", url: url("b"))
        library.addBookmark(name: "A again", url: url("a"))
        XCTAssertEqual(library.bookmarks.map(\.name), ["B", "A"])
    }

    func testUpdateBookmarkKeepsPositionIdentityAndDate() throws {
        let library = makeLibrary()
        library.addBookmark(name: "A", url: url("a"))
        library.addBookmark(name: "B", url: url("b"))
        let original = try XCTUnwrap(library.bookmarks.last)

        library.updateBookmark(original, name: "Renamed", url: url("c"))

        let updated = try XCTUnwrap(library.bookmarks.last)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.dateAdded, original.dateAdded)
        XCTAssertEqual(updated.name, "Renamed")
        XCTAssertEqual(updated.url, url("c"))
        XCTAssertEqual(library.bookmarks.map(\.name), ["B", "Renamed"])
    }

    func testUpdateBookmarkRefusesAnotherBookmarksURL() throws {
        let library = makeLibrary()
        library.addBookmark(name: "A", url: url("a"))
        library.addBookmark(name: "B", url: url("b"))
        let a = try XCTUnwrap(library.bookmarks.first { $0.name == "A" })

        library.updateBookmark(a, name: "A2", url: url("b"))

        XCTAssertEqual(library.bookmarks.map(\.name), ["B", "A"], "unchanged")
    }

    func testUpdateBookmarkMayKeepItsOwnURL() throws {
        let library = makeLibrary()
        library.addBookmark(name: "A", url: url("a"))
        let a = try XCTUnwrap(library.bookmarks.first)

        library.updateBookmark(a, name: "A2", url: url("a"))

        XCTAssertEqual(library.bookmarks.map(\.name), ["A2"])
    }

    func testBookmarksPersistAcrossInstances() {
        makeLibrary().addBookmark(name: "A", url: url("a"))
        XCTAssertEqual(makeLibrary().bookmarks.map(\.url), [url("a")])
    }

    // MARK: - History

    func testRecordVisitCollapsesARepeatOfTheNewestEntry() {
        let library = makeLibrary()
        library.recordVisit(title: "A", url: url("a"))
        library.recordVisit(title: "A, retitled", url: url("a"))
        library.recordVisit(title: "B", url: url("b"))
        library.recordVisit(title: "A", url: url("a"))
        XCTAssertEqual(library.history.map(\.title), ["A", "B", "A, retitled"])
    }

    func testRecordVisitIgnoresNonWebSchemes() {
        let library = makeLibrary()
        library.recordVisit(title: "Blank", url: URL(string: "about:blank")!)
        library.recordVisit(title: "File", url: URL(string: "file:///tmp/x")!)
        XCTAssertTrue(library.history.isEmpty)
    }

    func testClearHistorySinceDropsOnlyNewerEntries() throws {
        let library = makeLibrary()
        library.recordVisit(title: "Old", url: url("old"))
        library.recordVisit(title: "New", url: url("new"))
        let cutoff = try XCTUnwrap(library.history.first { $0.title == "New" }?.lastVisited)

        library.clearHistory(since: cutoff)

        XCTAssertEqual(library.history.map(\.title), ["Old"])
    }

    func testClearHistoryWithoutCutoffDropsEverything() {
        let library = makeLibrary()
        library.recordVisit(title: "A", url: url("a"))
        library.clearHistory()
        XCTAssertTrue(library.history.isEmpty)
        XCTAssertTrue(makeLibrary().history.isEmpty, "persisted")
    }

    private func url(_ path: String) -> URL {
        URL(string: "https://wiki.corp.example/\(path)")!
    }
}
