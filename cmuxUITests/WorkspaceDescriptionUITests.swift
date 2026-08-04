import XCTest
import Foundation
import CoreGraphics
import Darwin
import Vision

private func workspaceDescriptionPollUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    condition: () -> Bool
) -> Bool {
    let start = ProcessInfo.processInfo.systemUptime
    while true {
        if condition() {
            return true
        }
        if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
}

final class WorkspaceDescriptionUITests: XCTestCase {
    private var dataPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-workspace-description-\(UUID().uuidString).json"
        launchTag = "ui-tests-workspace-description-\(UUID().uuidString.lowercased())"
        try? FileManager.default.removeItem(atPath: dataPath)
    }

    func testCmdShiftEAllowsImmediateTypingAndSave() {
        let app = configuredApp()
        launchAndEnsureForeground(app)
        prepareTerminalFocusedWorkspace(app)

        let description = "Cmd Shift E focus note \(String(UUID().uuidString.prefix(8)))"
        app.typeKey("e", modifierFlags: [.command, .shift])

        let editor = requireDescriptionEditor(
            in: app,
            timeout: 5.0,
            failureMessage: "Expected Cmd+Shift+E to open the workspace description editor while terminal is focused"
        )

        app.typeText(description)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForNonExistence(editor, timeout: 5.0),
            "Expected Enter to save and dismiss the workspace description editor"
        )
        assertSavedDescription(description, in: app)
    }

    func testClickingDescriptionEditorAllowsTypingAndSave() {
        let app = configuredApp()
        launchAndEnsureForeground(app)
        prepareTerminalFocusedWorkspace(app)

        let description = "Clicked description note \(String(UUID().uuidString.prefix(8)))"
        app.typeKey("e", modifierFlags: [.command, .shift])

        let editor = requireDescriptionEditor(
            in: app,
            timeout: 5.0,
            failureMessage: "Expected Cmd+Shift+E to open the workspace description editor while terminal is focused"
        )

        clickDescriptionEditor(editor, in: app)
        app.typeText(description)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForNonExistence(editor, timeout: 5.0),
            "Expected Enter to save and dismiss the workspace description editor after clicking"
        )
        assertSavedDescription(description, in: app)
    }

    func testShiftEnterInsertsNewlineInsteadOfSubmitting() {
        let app = configuredApp()
        launchAndEnsureForeground(app)
        prepareTerminalFocusedWorkspace(app)

        let token = String(UUID().uuidString.prefix(8))
        let firstLine = "First line \(token)"
        let secondLine = "Second line \(token)"
        let description = "\(firstLine)\n\(secondLine)"

        app.typeKey("e", modifierFlags: [.command, .shift])

        let editor = requireDescriptionEditor(
            in: app,
            timeout: 5.0,
            failureMessage: "Expected Cmd+Shift+E to open the workspace description editor before testing Shift+Enter"
        )

        app.typeText(firstLine)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.shift])

        XCTAssertTrue(
            editor.exists,
            "Expected Shift+Enter to keep the workspace description editor open for multiline input"
        )

        app.typeText(secondLine)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForNonExistence(editor, timeout: 5.0),
            "Expected Enter to save and dismiss the workspace description editor after multiline input"
        )
        assertSavedDescription(description, in: app)
    }

    func testSidebarRendersSavedDescriptionWithLineBreaks() {
        let app = configuredSidebarApp()
        launchAndActivate(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 6.0))

        let token = String(UUID().uuidString.prefix(8))
        let firstLine = "Sidebar first \(token)"
        let secondLine = "Sidebar second \(token)"
        let description = "\(firstLine)\n\(secondLine)"

        app.typeKey("e", modifierFlags: [.command, .shift])

        let editor = requireDescriptionEditor(
            in: app,
            timeout: 5.0,
            failureMessage: "Expected Cmd+Shift+E to open the workspace description editor in a simple workspace"
        )

        app.typeText(firstLine)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.shift])
        app.typeText(secondLine)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForNonExistence(editor, timeout: 5.0),
            "Expected Enter to save and dismiss the workspace description editor after multiline input"
        )

        let renderedDescription = app
            .descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@", description))
            .firstMatch

        XCTAssertTrue(
            workspaceDescriptionPollUntil(timeout: 5.0) {
                renderedDescription.exists
            },
            "Expected the sidebar to render the saved multiline description with a newline-preserving label"
        )
    }

    private func configuredApp() -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        return app
    }

    private func configuredSidebarApp() -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        return app
    }

    private func prepareTerminalFocusedWorkspace(_ app: XCUIApplication) {
        XCTAssertTrue(
            waitForData(keys: ["terminalPaneId", "webViewFocused"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")

        guard let expectedTerminalPaneId = setup["terminalPaneId"] else {
            XCTFail("Missing terminalPaneId in goto_split setup data")
            return
        }

        app.typeKey("h", modifierFlags: [.command, .control])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["lastMoveDirection"] == "left" && data["focusedPaneId"] == expectedTerminalPaneId
            },
            "Expected Cmd+Ctrl+H to move focus to the terminal pane before opening the description editor"
        )
    }

    private func requireDescriptionEditor(
        in app: XCUIApplication,
        timeout: TimeInterval,
        failureMessage: String
    ) -> XCUIElement {
        guard let editor = firstExistingElement(
            candidates: descriptionEditorCandidates(in: app),
            timeout: timeout
        ) else {
            XCTFail(failureMessage)
            return app.textViews["CommandPaletteWorkspaceDescriptionEditor"].firstMatch
        }
        return editor
    }

    private func assertSavedDescription(_ description: String, in app: XCUIApplication) {
        app.typeKey("e", modifierFlags: [.command, .shift])

        let editor = requireDescriptionEditor(
            in: app,
            timeout: 5.0,
            failureMessage: "Expected Cmd+Shift+E to reopen the workspace description editor for verification"
        )

        XCTAssertTrue(
            waitForEditorValue(editor, expected: description, timeout: 5.0),
            "Expected the saved workspace description to be restored when reopening the editor. value=\(String(describing: editor.value))"
        )

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForNonExistence(editor, timeout: 5.0),
            "Expected Escape to dismiss the workspace description editor after verification"
        )
    }

    private func clickDescriptionEditor(_ editor: XCUIElement, in app: XCUIApplication) {
        if editor.exists {
            editor.click()
            return
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected app window for description editor click target")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).click()
    }

    private func descriptionEditorCandidates(in app: XCUIApplication) -> [XCUIElement] {
        [
            app.textViews["CommandPaletteWorkspaceDescriptionEditor"],
            app.scrollViews["CommandPaletteWorkspaceDescriptionEditor"],
            app.otherElements["CommandPaletteWorkspaceDescriptionEditor"],
        ]
    }

    private func firstExistingElement(
        candidates: [XCUIElement],
        timeout: TimeInterval
    ) -> XCUIElement? {
        var match: XCUIElement?
        let found = workspaceDescriptionPollUntil(timeout: timeout) {
            for candidate in candidates where candidate.exists {
                match = candidate
                return true
            }
            return false
        }
        return found ? match : nil
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground { return }
        if app.state == .runningBackground { return }

        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }

    private func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        app.launch()
        let activated = workspaceDescriptionPollUntil(timeout: activateTimeout) {
            guard app.state != .runningForeground else {
                return true
            }
            app.activate()
            return app.state == .runningForeground
        }
        if !activated {
            app.activate()
        }
        XCTAssertTrue(
            workspaceDescriptionPollUntil(timeout: 2.0) { app.state == .runningForeground },
            "App did not reach runningForeground before UI interactions"
        )
    }

    private func waitForData(keys: [String], timeout: TimeInterval) -> Bool {
        workspaceDescriptionPollUntil(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return keys.allSatisfy { data[$0] != nil }
        }
    }

    private func waitForDataMatch(timeout: TimeInterval, predicate: @escaping ([String: String]) -> Bool) -> Bool {
        workspaceDescriptionPollUntil(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return predicate(data)
        }
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForEditorValue(_ editor: XCUIElement, expected: String, timeout: TimeInterval) -> Bool {
        workspaceDescriptionPollUntil(timeout: timeout) {
            guard editor.exists else { return false }
            let value = (editor.value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value == expected
        }
    }

    private func loadData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}

final class ProjectWorktreeSidebarDescriptionUITests: XCTestCase {
    private static let providerID = "com.example.cmux.sidebar.project-worktrees"

    private var socketPath = ""
    private var diagnosticsPath = ""
    private var launchTag = ""
    private var appLogURL: URL?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let token = UUID().uuidString.lowercased()
        launchTag = "ui-tests-project-worktree-description-\(token.prefix(8))"
        socketPath = "/tmp/cmux-debug-\(launchTag).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-project-worktree-description-\(token).json"
        appLogURL = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        if let appLogURL {
            try? FileManager.default.removeItem(at: appLogURL)
        }
        super.tearDown()
    }

    func testCustomDescriptionReplacesBranchSubtitle() throws {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let branch = "issue-4889-branch"
        let workspaceName = "Issue 4889 \(token)"
        let customDescription = "Custom workspace description"
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-project-worktree-\(token)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        try createGitRepository(at: repository, branch: branch)

        let app = configuredApp()
        let appProcess = try launchAppProcess(using: app)
        defer { terminateAppProcess(appProcess) }

        let cliURL = try bundledCLIURL()
        var lastPing: CommandResult?
        XCTAssertTrue(
            workspaceDescriptionPollUntil(timeout: 15.0) {
                let result = self.runCLI(cliURL, arguments: ["ping"])
                lastPing = result
                return result.terminationStatus == 0 && result.stdout == "PONG"
            },
            "Expected bundled cmux CLI to reach the tagged app at \(socketPath). " +
                "processRunning=\(appProcess.isRunning) " +
                "pingStatus=\(String(describing: lastPing?.terminationStatus)) " +
                "pingStdout=\(lastPing?.stdout ?? "") pingStderr=\(lastPing?.stderr ?? "") " +
                "diagnostics=\(loadDiagnostics()) " +
                "appLog=\(appLogContents())"
        )

        let creation = runCLI(
            cliURL,
            arguments: [
                "new-workspace",
                "--name", workspaceName,
                "--description", customDescription,
                "--cwd", repository.path,
                "--focus", "true",
            ]
        )
        XCTAssertEqual(
            creation.terminationStatus,
            0,
            "Expected cmux new-workspace to succeed. stdout=\(creation.stdout) stderr=\(creation.stderr)"
        )
        guard creation.stdout.hasPrefix("OK ") else {
            return XCTFail("Expected cmux new-workspace to return a workspace reference. stdout=\(creation.stdout)")
        }

        let normalizedDescription = normalizedOCRText(customDescription)
        let normalizedBranch = normalizedOCRText(branch)
        var observedSubtitle: String?
        var recognizedSidebarText: [String] = []
        var screenshotDiagnostic = "No screenshot captured"

        XCTAssertTrue(
            workspaceDescriptionPollUntil(timeout: 20.0, pollInterval: 0.5) {
                do {
                    recognizedSidebarText = try self.captureRecognizedSidebarText(using: cliURL)
                    screenshotDiagnostic = "Recognized sidebar text: \(recognizedSidebarText)"
                    observedSubtitle = recognizedSidebarText.first { text in
                        let normalized = self.normalizedOCRText(text)
                        return normalized == normalizedDescription || normalized == normalizedBranch
                    }
                    return observedSubtitle != nil
                } catch {
                    screenshotDiagnostic = error.localizedDescription
                    return false
                }
            },
            "Expected the Project Worktrees sidebar to render either the custom description or branch subtitle. \(screenshotDiagnostic)"
        )

        XCTAssertEqual(
            observedSubtitle.map(normalizedOCRText),
            normalizedDescription,
            "Expected Project Worktrees to render customDescription as the workspace subtitle. " +
                "observed=\(String(describing: observedSubtitle)) sidebarText=\(recognizedSidebarText)"
        )
        XCTAssertNotEqual(
            observedSubtitle.map(normalizedOCRText),
            normalizedBranch,
            "The git branch must only be the fallback subtitle. sidebarText=\(recognizedSidebarText)"
        )
    }

    private func captureRecognizedSidebarText(using cliURL: URL) throws -> [String] {
        let screenshot = runCLI(
            cliURL,
            arguments: [
                "rpc",
                "debug.window.screenshot",
                #"{"label":"issue-4889-test"}"#,
            ]
        )
        guard screenshot.terminationStatus == 0 else {
            throw NSError(
                domain: "ProjectWorktreeSidebarDescriptionUITests",
                code: Int(screenshot.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Screenshot RPC failed. stdout=\(screenshot.stdout) stderr=\(screenshot.stderr)",
                ]
            )
        }
        guard let data = screenshot.stdout.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = payload["path"] as? String else {
            throw NSError(
                domain: "ProjectWorktreeSidebarDescriptionUITests",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Screenshot RPC returned an invalid payload. stdout=\(screenshot.stdout)",
                ]
            )
        }

        let screenshotURL = URL(fileURLWithPath: path)
        defer { try? FileManager.default.removeItem(at: screenshotURL) }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 0.35, height: 1)

        let handler = VNImageRequestHandler(url: screenshotURL, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }
    }

    private func normalizedOCRText(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func configuredApp() -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += [
            "-socketControlMode", "allowAll",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-NSAppSleepDisabled", "YES",
            "-cmuxExtensionSidebar.providerId", Self.providerID,
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        return app
    }

    private func launchAppProcess(using app: XCUIApplication) throws -> Process {
        let process = Process()
        process.executableURL = try appBinaryURL()
        process.arguments = app.launchArguments

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in app.launchEnvironment {
            environment[key] = value
        }
        process.environment = environment

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-project-worktree-description-\(launchTag).log")
        appLogURL = logURL
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        return process
    }

    private func appLogContents() -> String {
        guard let appLogURL,
              let data = try? Data(contentsOf: appLogURL),
              let contents = String(data: data, encoding: .utf8) else {
            return "<unavailable>"
        }
        return String(contents.suffix(4_000))
    }

    private func loadDiagnostics() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [:]) { result, entry in
            result[entry.key] = String(describing: entry.value)
        }
    }

    private func appBinaryURL() throws -> URL {
        let productsDirectory = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = productsDirectory.lastPathComponent.lowercased()
        let productNames = configuration.contains("release")
            ? ["cmux", "cmux DEV"]
            : ["cmux DEV", "cmux"]

        let candidates = productNames.map { productName in
            productsDirectory
                .appendingPathComponent("\(productName).app", isDirectory: true)
                .appendingPathComponent("Contents/MacOS/\(productName)", isDirectory: false)
        }
        if let binaryURL = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return binaryURL
        }
        throw NSError(
            domain: "ProjectWorktreeSidebarDescriptionUITests",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "App binary not found at \(candidates.map(\.path).joined(separator: " or ")). " +
                    "testBundle=\(Bundle(for: Self.self).bundleURL.path)",
            ]
        )
    }

    private func terminateAppProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        _ = workspaceDescriptionPollUntil(timeout: 5.0, pollInterval: 0.1) {
            !process.isRunning
        }
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    private func createGitRepository(at url: URL, branch: String) throws {
        let gitURL = try gitExecutableURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try requireSuccess(executableURL: gitURL, arguments: ["init", url.path])
        try requireSuccess(
            executableURL: gitURL,
            arguments: ["-C", url.path, "checkout", "-b", branch]
        )
        try requireSuccess(
            executableURL: gitURL,
            arguments: ["-C", url.path, "config", "user.email", "cmux-ui-test@example.test"]
        )
        try requireSuccess(
            executableURL: gitURL,
            arguments: ["-C", url.path, "config", "user.name", "cmux UI Test"]
        )
        try Data("issue 4889 fixture\n".utf8).write(to: url.appendingPathComponent("README.md"))
        try requireSuccess(
            executableURL: gitURL,
            arguments: ["-C", url.path, "add", "README.md"]
        )
        try requireSuccess(
            executableURL: gitURL,
            arguments: ["-C", url.path, "commit", "-m", "Initial fixture"]
        )
    }

    private func gitExecutableURL() throws -> URL {
        var candidates: [URL] = []
        if let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           !developerDirectory.isEmpty {
            candidates.append(
                URL(fileURLWithPath: developerDirectory, isDirectory: true)
                    .appendingPathComponent("usr/bin/git", isDirectory: false)
            )
        }
        if let applications = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications", isDirectory: true),
            includingPropertiesForKeys: nil
        ) {
            candidates.append(contentsOf: applications
                .filter { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
                .map { $0.appendingPathComponent("Contents/Developer/usr/bin/git", isDirectory: false) })
        }
        candidates.append(URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/bin/git"))

        if let gitURL = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return gitURL
        }
        throw NSError(
            domain: "ProjectWorktreeSidebarDescriptionUITests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate a real git executable outside the xcrun shim"]
        )
    }

    private func bundledCLIURL() throws -> URL {
        var productDirectories: [URL] = []
        if let builtProductsDirectory = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"],
           !builtProductsDirectory.isEmpty {
            productDirectories.append(URL(fileURLWithPath: builtProductsDirectory, isDirectory: true))
        }

        for bundleURL in [Bundle.main.bundleURL, Bundle(for: Self.self).bundleURL] {
            let components = bundleURL.standardizedFileURL.path.split(separator: "/")
            guard let productsIndex = components.firstIndex(of: "Products"),
                  productsIndex + 1 < components.count else {
                continue
            }
            let productPath = "/" + components.prefix(productsIndex + 2).joined(separator: "/")
            productDirectories.append(URL(fileURLWithPath: productPath, isDirectory: true))
        }

        var seen = Set<String>()
        for directory in productDirectories where seen.insert(directory.path).inserted {
            var appURLs = [
                directory.appendingPathComponent("cmux DEV.app", isDirectory: true),
                directory.appendingPathComponent("cmux.app", isDirectory: true),
            ]
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) {
                appURLs.append(contentsOf: entries.filter { $0.pathExtension == "app" })
            }
            for appURL in appURLs {
                let cliURL = appURL.appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
                if FileManager.default.isExecutableFile(atPath: cliURL.path) {
                    return cliURL
                }
            }
        }

        throw NSError(
            domain: "ProjectWorktreeSidebarDescriptionUITests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate the bundled cmux CLI"]
        )
    }

    private func runCLI(_ cliURL: URL, arguments: [String]) -> CommandResult {
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "CMUX_SOCKET", "CMUX_SOCKET_PATH", "CMUX_SOCKET_PASSWORD",
            "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID", "CMUX_WINDOW_ID",
            "CMUX_TAG", "CMUX_BUNDLE_ID", "CMUX_BUNDLED_CLI_PATH",
        ] {
            environment.removeValue(forKey: key)
        }
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "10"
        return runProcess(
            executableURL: cliURL,
            arguments: ["--socket", socketPath] + arguments,
            environment: environment
        )
    }

    private func requireSuccess(executableURL: URL, arguments: [String]) throws {
        let result = runProcess(
            executableURL: executableURL,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment
        )
        guard result.terminationStatus == 0 else {
            throw NSError(
                domain: "ProjectWorktreeSidebarDescriptionUITests",
                code: Int(result.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Command failed: \(executableURL.path) \(arguments.joined(separator: " ")). " +
                        "stdout=\(result.stdout) stderr=\(result.stderr)",
                ]
            )
        }
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(terminationStatus: -1, stdout: "", stderr: error.localizedDescription)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CommandResult(terminationStatus: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private struct CommandResult {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String
    }
}
