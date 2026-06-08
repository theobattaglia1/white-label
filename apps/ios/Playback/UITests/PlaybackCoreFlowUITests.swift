import XCTest

final class PlaybackCoreFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHomeDoesNotShowStartPanelWhenLibraryHasContent() {
        let app = launchPlayback()

        XCTAssertTrue(app.staticTexts["NEEDS YOUR EAR"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["Start your library"].waitForExistence(timeout: 1))
    }

    func testLibraryAddSongEntryPointShowsAudioAndArtworkInputs() {
        let app = launchPlayback(arguments: ["-tab", "library"])

        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 4))
        let addSong = app.buttons["ADD SONG"].firstMatch
        XCTAssertTrue(addSong.waitForExistence(timeout: 3))
        addSong.tap()

        XCTAssertTrue(app.navigationBars["Add song"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["AUDIO FILE"].exists)
        XCTAssertTrue(app.buttons["Choose audio"].exists)
        XCTAssertTrue(app.staticTexts["ARTWORK"].exists)
        XCTAssertTrue(app.buttons["Choose artwork"].exists)
    }

    func testExploreOpensProjectDetail() {
        let app = launchPlayback(arguments: ["-tab", "explore"])

        XCTAssertTrue(app.staticTexts["Explore"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["PROJECTS"].waitForExistence(timeout: 3))
        app.staticTexts["Hudson Ingram LP"].tap()

        XCTAssertTrue(app.staticTexts["PROJECT"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Hudson Ingram LP"].exists)
    }

    func testPlaylistDetailExposesReorderAffordance() {
        let app = launchPlayback(arguments: ["-playlist"])

        XCTAssertTrue(app.staticTexts["PLAYLIST"].waitForExistence(timeout: 4))
        let reorderHint = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "DRAG HANDLE")).firstMatch
        XCTAssertTrue(reorderHint.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["Drag to reorder The First Night"].waitForExistence(timeout: 3))
    }

    func testLibraryBulkSelectionShowsActionPalette() {
        let app = launchPlayback(arguments: ["-tab", "library"])

        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 4))
        app.buttons["SELECT"].firstMatch.tap()
        app.staticTexts["The First Night"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["SELECTED"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["1 song"].exists)
        XCTAssertTrue(app.staticTexts["PLAYLIST"].exists)
        XCTAssertTrue(app.staticTexts["PROJECT"].exists)
        XCTAssertTrue(app.staticTexts["SHARE"].exists)
        XCTAssertFalse(app.buttons["DELETE"].exists)
    }

    func testPlaylistBulkSelectionHidesReorderHandleAndCanRemove() {
        let app = launchPlayback(arguments: ["-playlist"])

        XCTAssertTrue(app.staticTexts["PLAYLIST"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["Drag to reorder The First Night"].waitForExistence(timeout: 3))

        app.buttons["SELECT"].firstMatch.tap()
        app.staticTexts["The First Night"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["SELECTED"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["REMOVE"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["Drag to reorder The First Night"].exists)
    }

    func testRealAuthModeShowsSignInGate() {
        let app = XCUIApplication()
        app.launchEnvironment["PLAYBACK_USE_REMOTE_API"] = "1"
        app.launchEnvironment["PLAYBACK_USE_REAL_AUTH"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Sign in"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.textFields["Email"].exists)
        XCTAssertTrue(app.secureTextFields["Password"].exists)
    }

    private func launchPlayback(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["PLAYBACK_USE_REMOTE_API"] = "0"
        app.launch()
        return app
    }
}
