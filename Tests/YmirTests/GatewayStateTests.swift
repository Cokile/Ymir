import XCTest
@testable import Ymir

final class GatewayStateTests: XCTestCase {
    func testGatewayStateCombinesHealthAndUserIntent() {
        XCTAssertEqual(GatewayState(isRunning: false, shouldBeRunning: false, isRestarting: false), .stopped)
        XCTAssertEqual(GatewayState(isRunning: false, shouldBeRunning: true, isRestarting: false), .starting)
        XCTAssertEqual(GatewayState(isRunning: true, shouldBeRunning: true, isRestarting: false), .running)
        XCTAssertEqual(GatewayState(isRunning: true, shouldBeRunning: false, isRestarting: false), .running)
        XCTAssertEqual(GatewayState(isRunning: true, shouldBeRunning: true, isRestarting: true), .starting)
        XCTAssertEqual(GatewayState(isRunning: false, shouldBeRunning: true, isRestarting: true), .starting)
    }

    func testStartImmediatelyEntersLoadingStateUntilHealthy() {
        let manager = CopilotAPIManager()
        XCTAssertEqual(manager.state, .stopped)
        manager.requestStart()
        XCTAssertEqual(manager.state, .starting)
        XCTAssertNil(manager.supervise(isRunning: true))
        XCTAssertEqual(manager.state, .running)
    }

    func testExhaustedRetriesStopLoadingAndAllowStartAgain() {
        // A zero retry budget exercises give-up without launching a real gateway.
        let manager = CopilotAPIManager(maxRestartAttempts: 0)
        manager.requestStart()
        XCTAssertNotNil(manager.supervise(isRunning: false))
        XCTAssertFalse(manager.shouldBeRunning)
        XCTAssertEqual(manager.state, .stopped)
        XCTAssertNil(manager.supervise(isRunning: false))
        manager.requestStart()
        XCTAssertEqual(manager.state, .starting)
    }
}
