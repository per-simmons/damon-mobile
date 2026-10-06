import XCTest

/// Drives the app for a screen recording: open an agent, open the demo chat,
/// type a prompt, send it, and wait for the agent to finish replying.
/// Run with TEST_RUNNER_DEMO_PANE / TEST_RUNNER_DEMO_AGENT / TEST_RUNNER_DEMO_PROMPT.
final class DemoRecording: XCTestCase {
	func testDemo() throws {
		let env = ProcessInfo.processInfo.environment
		let pane = env["DEMO_PANE"] ?? ""
		let agent = env["DEMO_AGENT"] ?? ""
		let prompt = env["DEMO_PROMPT"] ?? "Hello"

		let app = XCUIApplication()
		app.launchArguments = ["-demo", "-demoPane", pane]
		app.launch()

		let agentLabel = app.staticTexts[agent].firstMatch
		XCTAssertTrue(agentLabel.waitForExistence(timeout: 20))
		sleep(3)
		agentLabel.tap()
		sleep(1)

		let title = env["DEMO_CHAT"] ?? "Mobile chat"
		let chat = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
		XCTAssertTrue(chat.waitForExistence(timeout: 10))
		chat.tap()
		sleep(3)

		let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
		XCTAssertTrue(composer.waitForExistence(timeout: 10))
		composer.tap()
		sleep(1)
		composer.typeText(prompt)
		sleep(1)
		app.buttons["Send"].firstMatch.tap()

		let working = app.staticTexts["Working"].firstMatch
		_ = working.waitForExistence(timeout: 30)
		let done = NSPredicate(format: "exists == false")
		expectation(for: done, evaluatedWith: working)
		waitForExpectations(timeout: 240)
		sleep(4)
	}

	/// Second take: scroll every rail, then + -> Codex on an agent, prompt, reply.
	func testCodexDemo() throws {
		let env = ProcessInfo.processInfo.environment
		let agent = env["DEMO_AGENT"] ?? ""
		let prompt = env["DEMO_PROMPT"] ?? "Hello"
		let mark = { (name: String) in print("DEMO-MARK \(name) \(Date().timeIntervalSince1970)") }

		let app = XCUIApplication()
		app.launchArguments = ["-demo", "-demoPane", "none"]
		app.launch()
		XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 20))
		mark("app-ready")
		sleep(6) // under load the first frames reach the recorder seconds late; hold at the top
		mark("scroll-start")
		// One short, slow scroll down to show a few more rails, then back to the
		// top. Steady drags with a hold, so the list doesn't coast.
		let list = app.collectionViews.firstMatch
		func drag(_ from: CGFloat, _ to: CGFloat) {
			let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
			let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
			start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 600, thenHoldForDuration: 0.4)
		}
		// One short scroll that keeps the agent on screen, then the + press right
		// there. (A drag back to the top kept falling into a recorder gap.)
		drag(0.75, 0.52)
		usleep(1_200_000)

		// Short presses instead of instant taps, so the touch circle registers on camera.
		app.buttons["New chat with \(agent)"].firstMatch.press(forDuration: 0.6)
		XCTAssertTrue(app.buttons["Codex"].firstMatch.waitForExistence(timeout: 5))
		usleep(900_000)
		// Mark before tapping: tap() only returns once the app idles, seconds later.
		mark("codex-starting")
		app.buttons["Codex"].firstMatch.press(forDuration: 0.3)

		let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
		XCTAssertTrue(composer.waitForExistence(timeout: 20))
		let enabled = NSPredicate(format: "enabled == true")
		expectation(for: enabled, evaluatedWith: composer)
		waitForExpectations(timeout: 30)
		mark("codex-ready")
		sleep(1)
		composer.tap()
		// A few words at a time: reads like real typing, and a burst can fall entirely
		// between two frames when the recorder is starved for CPU.
		let words = prompt.split(separator: " ").map(String.init)
		for start in stride(from: 0, to: words.count, by: 3) {
			let chunk = words[start..<min(start + 3, words.count)].joined(separator: " ")
			composer.typeText(start + 3 < words.count ? chunk + " " : chunk)
			usleep(60_000)
		}
		sleep(1)
		app.buttons["Send"].firstMatch.press(forDuration: 0.3)
		mark("sent")

		let working = app.staticTexts["Working"].firstMatch
		_ = working.waitForExistence(timeout: 20)
		expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: working)
		waitForExpectations(timeout: 240)
		mark("replied")
		sleep(4)
	}
}
