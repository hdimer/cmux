import Foundation
import XCTest

final class PasteBufferLargePayloadUITests: XCTestCase {
    private var socketPath = ""
    private var taggedSocketPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-paste-buffer-\(UUID().uuidString).sock"
        launchTag = "ui-tests-paste-buffer-\(UUID().uuidString.prefix(8))"
        taggedSocketPath = Self.taggedSocketPath(for: launchTag)
        removeSocketFiles()
    }

    override func tearDown() {
        removeSocketFiles()
        super.tearDown()
    }

    func testLargeMultilinePasteBufferPreservesEveryMarkerInOrder() throws {
        print("Paste-buffer regression host: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let app = configuredApp()
        defer { app.terminate() }

        // This flow is socket-driven, so a backgrounded app is sufficient.
        // Hosted runners can start the process but fail XCUI's foreground
        // activation with the app left in .runningBackground.
        let launchOptions = XCTExpectedFailure.Options()
        launchOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: launchOptions) {
            app.launch()
        }

        XCTAssertTrue(
            app.state == .runningForeground || app.state == .runningBackground,
            "Expected the tagged cmux test app to launch"
        )

        var resolvedSocketPath: String?
        XCTAssertTrue(
            waitForControlSocketReady(
                pingTimeout: 12.0,
                socketFileExists: {
                    self.socketCandidates.contains {
                        FileManager.default.fileExists(atPath: $0)
                    }
                },
                pingReturnsPong: {
                    for candidate in self.socketCandidates {
                        guard FileManager.default.fileExists(atPath: candidate) else { continue }
                        if self.controlSocketCommandViaNetcat("ping", socketPath: candidate) == "PONG" {
                            resolvedSocketPath = candidate
                            return true
                        }
                    }
                    return false
                }
            ),
            "Expected a responsive tagged control socket at \(socketCandidates)"
        )

        let liveSocketPath = try XCTUnwrap(resolvedSocketPath)
        let cliPath = try XCTUnwrap(
            bundledCLIPath(),
            "Expected the built app to contain Contents/Resources/bin/cmux"
        )
        let bufferName = "issue-5138-\(UUID().uuidString)"
        let expectedMarkers = (1...80).map { String(format: "MARK%04d", $0) }
        let payload = expectedMarkers.map { "\($0) \(String(repeating: "x", count: 48))" }
            .joined(separator: "\n")
        XCTAssertEqual(payload.utf8.count, 4_639)

        let create = runCLI(
            cliPath: cliPath,
            socketPath: liveSocketPath,
            arguments: [
                "workspace", "create",
                "--name", "paste-buffer-regression",
                "--cwd", "/tmp",
                "--command", "cat",
                "--focus", "false",
            ]
        )
        XCTAssertEqual(create.status, 0, create.diagnostic)
        let workspace = try XCTUnwrap(
            create.stdout.split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .first(where: { $0.hasPrefix("workspace:") }),
            "Expected workspace.create to return a workspace ref. \(create.diagnostic)"
        )

        // Prove the cat PTY is live before the large send. A sufficiently slow
        // host can otherwise queue the whole payload on the cold-surface path,
        // which does not exercise the live Ghostty write burst from #5138.
        let readinessMarker = "PASTE_BUFFER_READY_\(UUID().uuidString)"
        let readinessSend = runCLI(
            cliPath: cliPath,
            socketPath: liveSocketPath,
            arguments: ["send", "--workspace", workspace, "--", readinessMarker + "\n"]
        )
        XCTAssertEqual(readinessSend.status, 0, readinessSend.diagnostic)

        var readinessScreen = ""
        let readinessDeadline = Date().addingTimeInterval(12.0)
        repeat {
            let readScreen = runCLI(
                cliPath: cliPath,
                socketPath: liveSocketPath,
                arguments: ["read-screen", "--workspace", workspace, "--scrollback"]
            )
            XCTAssertEqual(readScreen.status, 0, readScreen.diagnostic)
            readinessScreen = readScreen.stdout
            if readinessScreen.contains(readinessMarker) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < readinessDeadline
        XCTAssertTrue(
            readinessScreen.contains(readinessMarker),
            "Expected the cat workspace to echo the readiness marker before the large paste"
        )

        let setBuffer = runCLI(
            cliPath: cliPath,
            socketPath: liveSocketPath,
            arguments: ["set-buffer", "--name", bufferName, "--", payload]
        )
        XCTAssertEqual(setBuffer.status, 0, setBuffer.diagnostic)

        let pasteBuffer = runCLI(
            cliPath: cliPath,
            socketPath: liveSocketPath,
            arguments: [
                "paste-buffer", "--name", bufferName,
                "--workspace", workspace,
            ]
        )
        XCTAssertEqual(pasteBuffer.status, 0, pasteBuffer.diagnostic)

        var captured = ""
        let deadline = Date().addingTimeInterval(12.0)
        repeat {
            let readScreen = runCLI(
                cliPath: cliPath,
                socketPath: liveSocketPath,
                arguments: ["read-screen", "--workspace", workspace, "--scrollback"]
            )
            XCTAssertEqual(readScreen.status, 0, readScreen.diagnostic)
            captured = readScreen.stdout
            if captured.contains("MARK0080") { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline

        let actualMarkers = try orderedDistinctMarkers(in: captured)
        XCTAssertEqual(
            actualMarkers,
            expectedMarkers,
            markerFailureMessage(expected: expectedMarkers, actual: actualMarkers)
        )
    }

    private var socketCandidates: [String] {
        [socketPath, taggedSocketPath]
    }

    private func configuredApp() -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += [
            "-socketControlMode", "allowAll",
            "-NSAppSleepDisabled", "YES",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        return app
    }

    private func runCLI(
        cliPath: String,
        socketPath: String,
        arguments: [String]
    ) -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["--socket", socketPath] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "12"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CLIResult(
                status: -1,
                stdout: "",
                stderr: "Failed to run \(cliPath): \(error.localizedDescription)"
            )
        }

        return CLIResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func bundledCLIPath() -> String? {
        var productDirectories: [String] = []
        let environment = ProcessInfo.processInfo.environment
        if let builtProducts = environment["BUILT_PRODUCTS_DIR"], !builtProducts.isEmpty {
            productDirectories.append(builtProducts)
        }
        if let testHost = environment["TEST_HOST"], !testHost.isEmpty {
            var productsURL = URL(fileURLWithPath: testHost)
            for _ in 0..<4 {
                productsURL.deleteLastPathComponent()
            }
            productDirectories.append(productsURL.path)
        }
        for bundleURL in [Bundle.main.bundleURL, Bundle(for: Self.self).bundleURL] {
            let components = bundleURL.standardizedFileURL.path.split(separator: "/")
            guard let products = components.firstIndex(of: "Products"), products + 1 < components.count else {
                continue
            }
            productDirectories.append("/" + components.prefix(products + 2).joined(separator: "/"))
        }

        var candidates: [String] = []
        for directory in Self.orderedDistinct(productDirectories) {
            candidates.append("\(directory)/cmux DEV.app/Contents/Resources/bin/cmux")
            candidates.append("\(directory)/cmux.app/Contents/Resources/bin/cmux")
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) {
                for entry in entries.sorted() where entry.hasSuffix(".app") {
                    candidates.append("\(directory)/\(entry)/Contents/Resources/bin/cmux")
                }
            }
        }
        return Self.orderedDistinct(candidates).first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private func orderedDistinctMarkers(in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"MARK[0-9]{4}"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
        return Self.orderedDistinct(matches)
    }

    private func markerFailureMessage(expected: [String], actual: [String]) -> String {
        let actualSet = Set(actual)
        let missing = expected.filter { !actualSet.contains($0) }
        return "Expected all 80 markers in order; missing=\(missing) actual=\(actual)"
    }

    private func removeSocketFiles() {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath)
    }

    private static func taggedSocketPath(for tag: String) -> String {
        let slug = tag.lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "/tmp/cmux-debug-\(slug).sock"
    }

    private static func orderedDistinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private struct CLIResult {
        let status: Int32
        let stdout: String
        let stderr: String

        var diagnostic: String {
            "status=\(status) stdout=\(stdout.debugDescription) stderr=\(stderr.debugDescription)"
        }
    }
}
