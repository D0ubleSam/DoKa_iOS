import XCTest
@testable import Doka

final class AIEntitlementTests: XCTestCase {
    private func entitlement(_ json: String) throws -> AIEntitlementPayload {
        try JSONDecoder().decode(AIEntitlementPayload.self, from: Data(json.utf8))
    }

    func testVIPCanComposeWithoutRemainingFreeUses() throws {
        let result = try entitlement(#"{"is_vip":true,"remaining_compose_count":0}"#)
        XCTAssertTrue(result.isVIP)
        XCTAssertTrue(result.canCompose)
        XCTAssertEqual(result.remainingCount, 0)
    }

    func testEachSupportedCounterCanGrantNonVIPAccess() throws {
        for key in ["remaining_compose_count", "ai_compose_remaining_count", "remaining_free_count"] {
            let result = try entitlement("{\"is_vip\":false,\"\(key)\":3}")
            XCTAssertFalse(result.isVIP)
            XCTAssertTrue(result.canCompose)
            XCTAssertEqual(result.remainingCount, 3)
        }
    }

    func testAbsentNullAndEmptyEntitlementsDenyComposition() throws {
        for json in ["{}", #"{"is_vip":null,"remaining_compose_count":null}"#,
                     #"{"is_vip":false,"remaining_compose_count":0}"#] {
            let result = try entitlement(json)
            XCTAssertFalse(result.isVIP)
            XCTAssertFalse(result.canCompose)
            XCTAssertEqual(result.remainingCount, 0)
        }
    }

    func testNegativeCountersAreClampedToZero() throws {
        for key in ["remaining_compose_count", "ai_compose_remaining_count", "remaining_free_count"] {
            let result = try entitlement("{\"\(key)\":-10}")
            XCTAssertEqual(result.remainingCount, 0)
            XCTAssertFalse(result.canCompose)
        }
    }

    func testModernCounterTakesPriorityIncludingAnExplicitZero() throws {
        let result = try entitlement(#"{"remaining_compose_count":0,"ai_compose_remaining_count":5,"remaining_free_count":10}"#)
        XCTAssertEqual(result.remainingCount, 0)
        XCTAssertFalse(result.canCompose)
    }

    func testAlternateCounterTakesPriorityOverLegacyCounter() throws {
        let result = try entitlement(#"{"remaining_compose_count":null,"ai_compose_remaining_count":2,"remaining_free_count":10}"#)
        XCTAssertEqual(result.remainingCount, 2)
        XCTAssertTrue(result.canCompose)
    }

    func testNullCountersFallBackToLegacyValue() throws {
        let result = try entitlement(#"{"remaining_compose_count":null,"ai_compose_remaining_count":null,"remaining_free_count":4}"#)
        XCTAssertEqual(result.remainingCount, 4)
        XCTAssertTrue(result.canCompose)
    }

    func testNegativeModernCounterCannotBeOverriddenByLegacyCredit() throws {
        let result = try entitlement(#"{"remaining_compose_count":-1,"remaining_free_count":10}"#)
        XCTAssertEqual(result.remainingCount, 0)
        XCTAssertFalse(result.canCompose)
    }

    func testMalformedEntitlementTypesFailClosed() {
        for json in [#"{"is_vip":"true"}"#, #"{"is_vip":1}"#,
                     #"{"remaining_compose_count":"10"}"#, #"{"remaining_free_count":1.5}"#] {
            XCTAssertThrowsError(try entitlement(json), json)
        }
    }
}
