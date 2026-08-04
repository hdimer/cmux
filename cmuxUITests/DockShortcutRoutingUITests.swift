import Foundation
import XCTest

/// End-to-end regression coverage for issue #9518. The control socket builds
/// real main-area and right-sidebar Dock browser trees, then `simulate_shortcut`
/// enters the same AppDelegate matcher/dispatcher used by keyboard events. This
/// keeps the assertions deterministic on headless hosted runners while still
/// exercising the production focus and closed-panel paths.
final class DockShortcutRoutingUITests: XCTestCase {
    private struct CreatedSurface {
        let id: String
        let containerID: String
    }

    private struct BrowserTabState: Equatable {
        let id: String
        let url: String
    }

    private var app: XCUIApplication?
    private var isolatedHome: URL!
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let token = UUID().uuidString
        isolatedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-ui-test-dock-shortcuts-\(token)",
            isDirectory: true
        )
        socketPath = "/tmp/cmux-ui-test-dock-shortcuts-\(token).sock"
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        removeSocketFiles()
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        removeSocketFiles()
        if let isolatedHome {
            try? FileManager.default.removeItem(at: isolatedHome)
        }
        super.tearDown()
    }

    func testCmdLFocusesDockBrowserAddressBar() throws {
        launchIsolatedApp()

        let mainWorkspaceID = try XCTUnwrap(currentWorkspaceID())
        let mainBrowser = try createBrowserSurface(
            url: "https://main-address.example/",
            containerID: mainWorkspaceID
        )
        let dockBrowser = try createBrowserSurface(
            url: "https://dock-address.example/",
            placement: "dock"
        )

        try focusDockBrowser(dockBrowser)
        XCTAssertTrue(
            waitUntil(timeout: 5.0) { self.focusedAddressBarSurfaceID() == nil },
            "Expected the Dock browser WebView, not an address bar, to own focus before Cmd+L"
        )

        simulateShortcut("cmd+l")

        let routedToDock = waitUntil(timeout: 8.0) {
            self.focusedAddressBarSurfaceID() == dockBrowser.id
        }
        let focusedSurfaceID = focusedAddressBarSurfaceID()
        XCTAssertTrue(
            routedToDock,
            "Cmd+L should focus the Dock browser address bar. " +
                "dock=\(dockBrowser.id) main=\(mainBrowser.id) actual=\(focusedSurfaceID ?? "nil")"
        )
    }

    func testCmdShiftTReopensDockBrowserWithoutChangingMainArea() throws {
        launchIsolatedApp()

        let mainWorkspaceID = try XCTUnwrap(currentWorkspaceID())
        _ = try createBrowserSurface(
            url: "https://main-kept.example/",
            containerID: mainWorkspaceID
        )
        let mainClosed = try createBrowserSurface(
            url: "https://main-closed.example/",
            containerID: mainWorkspaceID
        )
        try closeSurface(mainClosed)

        let dockClosedURL = "https://dock-closed.example/"
        let dockClosed = try createBrowserSurface(url: dockClosedURL, placement: "dock")
        let dockRemaining = try createBrowserSurface(
            url: "https://dock-remaining.example/",
            placement: "dock"
        )
        XCTAssertEqual(dockClosed.containerID, dockRemaining.containerID)
        try closeSurface(dockClosed)
        try focusDockBrowser(dockRemaining)

        let mainSurfaceIDsBefore = try XCTUnwrap(surfaceIDs(containerID: mainWorkspaceID))
        let dockTabsBefore = try XCTUnwrap(browserTabs(containerID: dockRemaining.containerID))
        XCTAssertEqual(dockTabsBefore.map(\.id), [dockRemaining.id])
        XCTAssertFalse(dockTabsBefore.contains { urlHost($0.url) == urlHost(dockClosedURL) })

        simulateShortcut("cmd+shift+t")

        let restoredInDockOnly = waitUntil(timeout: 10.0) {
            guard let mainSurfaceIDs = self.surfaceIDs(containerID: mainWorkspaceID),
                  let dockTabs = self.browserTabs(containerID: dockRemaining.containerID) else {
                return false
            }
            return mainSurfaceIDs == mainSurfaceIDsBefore &&
                dockTabs.count == 2 &&
                dockTabs.contains { urlHost($0.url) == urlHost(dockClosedURL) }
        }

        let mainSurfaceIDsAfter = surfaceIDs(containerID: mainWorkspaceID) ?? []
        let dockTabsAfter = browserTabs(containerID: dockRemaining.containerID) ?? []
        XCTAssertTrue(
            restoredInDockOnly,
            "Cmd+Shift+T should restore the closed Dock browser and leave the main tree unchanged. " +
                "mainBefore=\(mainSurfaceIDsBefore.sorted()) mainAfter=\(mainSurfaceIDsAfter.sorted()) " +
                "dockBefore=\(dockTabsBefore) dockAfter=\(dockTabsAfter)"
        )
    }

    // MARK: - App and control socket

    private func launchIsolatedApp() {
        let application = XCUIApplication.cmuxTestApplication()
        application.launchEnvironment["HOME"] = isolatedHome.path
        application.launchEnvironment["CFFIXED_USER_HOME"] = isolatedHome.path
        application.launchEnvironment["XDG_CONFIG_HOME"] = isolatedHome
            .appendingPathComponent(".config", isDirectory: true).path
        application.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        application.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        application.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        application.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        application.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        application.launchEnvironment["CMUX_TAG"] = "ui-dock-shortcuts-\(UUID().uuidString.prefix(8))"
        application.launchArguments += [
            "-socketControlMode", "allowAll",
            "-rightSidebar.beta.dock.enabled", "YES",
            "-browserDisabledOverride", "NO",
            "-NSAppSleepDisabled", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app = application

        let launchOptions = XCTExpectedFailure.Options()
        launchOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless UI runners", options: launchOptions) {
            application.launch()
        }

        let launched = waitUntil(timeout: 15.0) {
            application.state == .runningForeground || application.state == .runningBackground
        }
        XCTAssertTrue(launched, "App failed to start. state=\(application.state.rawValue)")
        XCTAssertTrue(
            waitForControlSocketReady(
                socketPath: socketPath,
                pingTimeout: 20.0,
                pingReturnsPong: { self.socketCommand("ping") == "PONG" }
            ),
            "Control socket never answered ping at \(socketPath)"
        )
        XCTAssertEqual(socketCommand("activate_app", responseTimeout: 10.0), "OK")
    }

    private func currentWorkspaceID() -> String? {
        guard let reply = socketCommand("current_workspace"), UUID(uuidString: reply) != nil else {
            return nil
        }
        return reply
    }

    private func createBrowserSurface(
        url: String,
        placement: String? = nil,
        containerID: String? = nil
    ) throws -> CreatedSurface {
        var params: [String: Any] = [
            "type": "browser",
            "url": url,
            "focus": true,
        ]
        if let placement { params["placement"] = placement }
        if let containerID { params["workspace_id"] = containerID }

        let result = try XCTUnwrap(
            socketResult(method: "surface.create", params: params),
            "surface.create failed for \(url): \(String(describing: lastSocketEnvelope))"
        )
        let isDock = placement == "dock"
        let idKey = isDock ? "dock_surface_id" : "surface_id"
        let surfaceID = try XCTUnwrap(result[idKey] as? String)
        let resolvedContainerID = try XCTUnwrap(result["workspace_id"] as? String)
        return CreatedSurface(id: surfaceID, containerID: resolvedContainerID)
    }

    private func closeSurface(_ surface: CreatedSurface) throws {
        let result = try XCTUnwrap(socketResult(
            method: "surface.close",
            params: [
                "workspace_id": surface.containerID,
                "surface_id": surface.id,
            ]
        ))
        XCTAssertEqual(result["surface_id"] as? String, surface.id)
        XCTAssertTrue(
            waitUntil(timeout: 5.0) {
                self.surfaceIDs(containerID: surface.containerID)?.contains(surface.id) == false
            },
            "Surface \(surface.id) remained present after close"
        )
    }

    private func focusDockBrowser(_ surface: CreatedSurface) throws {
        let sidebarResult = try XCTUnwrap(socketResult(
            method: "debug.right_sidebar.focus",
            params: [
                "mode": "dock",
                "window_id": surface.containerID,
                "focus_first_item": false,
            ]
        ))
        XCTAssertEqual(sidebarResult["active_mode"] as? String, "dock")

        _ = try XCTUnwrap(socketResult(
            method: "surface.focus",
            params: [
                "workspace_id": surface.containerID,
                "surface_id": surface.id,
            ]
        ))
        XCTAssertTrue(
            waitUntil(timeout: 10.0) {
                self.socketResult(
                    method: "browser.focus_webview",
                    params: ["surface_id": surface.id]
                )?["focused"] as? Bool == true
            },
            "Dock browser WebView never became first responder: \(surface.id)"
        )
    }

    private func simulateShortcut(_ combo: String) {
        let reply = socketCommand("simulate_shortcut \(combo)", responseTimeout: 30.0)
        XCTAssertEqual(reply, "OK", "simulate_shortcut \(combo) failed: \(reply ?? "nil")")
    }

    // MARK: - State assertions

    private func focusedAddressBarSurfaceID() -> String? {
        socketResult(method: "debug.browser.address_bar_focused", params: [:])?["focused_surface_id"] as? String
    }

    private func surfaceIDs(containerID: String) -> Set<String>? {
        guard let result = socketResult(
            method: "surface.list",
            params: ["workspace_id": containerID]
        ), let surfaces = result["surfaces"] as? [[String: Any]] else {
            return nil
        }
        return Set(surfaces.compactMap { $0["id"] as? String })
    }

    private func browserTabs(containerID: String) -> [BrowserTabState]? {
        guard let result = socketResult(
            method: "browser.tab.list",
            params: ["workspace_id": containerID]
        ), let tabs = result["tabs"] as? [[String: Any]] else {
            return nil
        }
        return tabs.compactMap { tab in
            guard let id = tab["id"] as? String, let url = tab["url"] as? String else {
                return nil
            }
            return BrowserTabState(id: id, url: url)
        }
    }

    private func urlHost(_ string: String) -> String? {
        URL(string: string)?.host
    }

    // MARK: - Socket plumbing

    private var lastSocketEnvelope: [String: Any]?

    private func socketCommand(_ command: String, responseTimeout: TimeInterval = 5.0) -> String? {
        controlSocketCommandViaNetcat(
            command,
            socketPath: socketPath,
            responseTimeout: responseTimeout
        )
    }

    private func socketResult(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        let envelope = controlSocketJSONViaNetcat(
            request,
            socketPath: socketPath,
            responseTimeout: 10.0
        )
        lastSocketEnvelope = envelope
        guard envelope?["ok"] as? Bool == true else { return nil }
        return envelope?["result"] as? [String: Any]
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }

    private func removeSocketFiles() {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
    }
}
