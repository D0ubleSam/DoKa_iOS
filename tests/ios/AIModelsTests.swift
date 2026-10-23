import XCTest
import CoreGraphics
@testable import Doka

final class AIModelsTests: XCTestCase {
    private func payload(_ json: String) throws -> AICameraPayload {
        try JSONDecoder().decode(AICameraPayload.self, from: Data(json.utf8))
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 0.00000001, file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 0.00000001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.00000001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.00000001, file: file, line: line)
    }

    func testSuccessfulEnvelopeDecodesComposition() throws {
        let json = #"{"code":0,"message":"ok","data":{"SubAreaRectNorm":{"X":0.1,"Y":0.2,"W":0.6,"H":0.7}}}"#
        let envelope = try JSONDecoder().decode(APIEnvelope<AICameraPayload>.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.code, 0)
        XCTAssertEqual(envelope.message, "ok")
        let camera = try XCTUnwrap(envelope.data)
        let result = try camera.result(imageWidth: 1000, imageHeight: 2000)
        assertRect(result.rect, CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7))
    }

    func testEnvelopeAllowsMissingOrNullData() throws {
        for json in [#"{"code":0}"#, #"{"code":0,"data":null}"#] {
            let envelope = try JSONDecoder().decode(APIEnvelope<AICameraPayload>.self, from: Data(json.utf8))
            XCTAssertNil(envelope.data)
        }
    }

    func testEmptyAndMalformedEnvelopesFailDecoding() {
        for json in ["", "{}", #"{"code":"0","data":{}}"#, #"{"code":0,"data":[]}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(APIEnvelope<AICameraPayload>.self,
                                                        from: Data(json.utf8)), json)
        }
    }

    func testBothCoordinateKeyCasingsDecode() throws {
        for json in [
            #"{"SubAreaRectNorm":{"X":0.1,"Y":0.2,"W":0.6,"H":0.7}}"#,
            #"{"SubAreaRectNorm":{"x":0.1,"y":0.2,"w":0.6,"h":0.7}}"#,
            #"{"SubAreaRectNorm":{"X":0.1,"y":0.2,"W":0.6,"h":0.7}}"#
        ] {
            let result = try payload(json).result(imageWidth: 1000, imageHeight: 2000)
            assertRect(result.rect, CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7))
        }
    }

    func testPixelCoordinatesUseSubmittedImageDimensions() throws {
        let camera = try payload(#"{"LeftTopCrd":[100,400],"RightDownCrd":[700,1800]}"#)
        let result = try camera.result(imageWidth: 1000, imageHeight: 2000)
        assertRect(result.rect, CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7))
    }

    func testNullNormalizedRectFallsBackToPixels() throws {
        let camera = try payload(#"{"SubAreaRectNorm":null,"LeftTopCrd":[0,0],"RightDownCrd":[100,200]}"#)
        let result = try camera.result(imageWidth: 100, imageHeight: 200)
        assertRect(result.rect, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testNormalizedCoordinatesTakePriorityOverPixelCoordinates() throws {
        let camera = try payload(#"{"SubAreaRectNorm":{"X":0.1,"Y":0.2,"W":0.6,"H":0.7},"LeftTopCrd":[0,0],"RightDownCrd":[1000,2000]}"#)
        let result = try camera.result(imageWidth: 1000, imageHeight: 2000)
        assertRect(result.rect, CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7))
    }

    func testInvalidNormalizedRectWithoutValidPixelFallbackIsRejected() throws {
        let camera = try payload(#"{"SubAreaRectNorm":{"X":0.2,"Y":0.1,"W":0,"H":0.5}}"#)
        XCTAssertThrowsError(try camera.result(imageWidth: 100, imageHeight: 200)) { error in
            guard case AIServiceError.invalidComposition = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testEmptyPartialAndInvalidNormalizedRectsFallBackToValidPixels() throws {
        for normalizedJSON in ["{}", #"{"X":0,"Y":null,"W":1,"H":1}"#,
                               #"{"X":0,"Y":0,"W":0,"H":1}"#] {
            let camera = try payload("{\"SubAreaRectNorm\":\(normalizedJSON),\"LeftTopCrd\":[10,40],\"RightDownCrd\":[70,180]}")
            let result = try camera.result(imageWidth: 100, imageHeight: 200)
            assertRect(result.rect, CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7))
        }
    }

    func testIncompleteNormalizedRectWithoutPixelFallbackReportsMissingComposition() throws {
        for normalizedJSON in ["{}", #"{"X":0,"Y":null,"W":1,"H":1}"#] {
            let camera = try payload("{\"SubAreaRectNorm\":\(normalizedJSON)}")
            XCTAssertThrowsError(try camera.result(imageWidth: 100, imageHeight: 200)) { error in
                guard case AIServiceError.missingComposition = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testMissingOrIncompleteCoordinatesReportMissingComposition() throws {
        for json in ["{}", #"{"LeftTopCrd":[0,0]}"#,
                     #"{"LeftTopCrd":[0],"RightDownCrd":[100,200]}"#,
                     #"{"LeftTopCrd":[0,0],"RightDownCrd":[100,200,300]}"#] {
            let camera = try payload(json)
            XCTAssertThrowsError(try camera.result(imageWidth: 100, imageHeight: 200), json) { error in
                guard case AIServiceError.missingComposition = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testInvalidSubmittedImageDimensionsAreRejected() throws {
        let camera = try payload(#"{"SubAreaRectNorm":{"X":0,"Y":0,"W":1,"H":1}}"#)
        for (width, height) in [(0, 200), (100, 0), (-1, 200), (100, -1)] {
            XCTAssertThrowsError(try camera.result(imageWidth: width, imageHeight: height)) { error in
                guard case AIServiceError.invalidImage = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testReversedOrOutOfBoundsPixelCoordinatesAreRejected() throws {
        for json in [
            #"{"LeftTopCrd":[80,20],"RightDownCrd":[20,180]}"#,
            #"{"LeftTopCrd":[20,180],"RightDownCrd":[80,20]}"#,
            #"{"LeftTopCrd":[-1,20],"RightDownCrd":[80,180]}"#,
            #"{"LeftTopCrd":[20,20],"RightDownCrd":[101,180]}"#,
            #"{"LeftTopCrd":[20,20],"RightDownCrd":[80,201]}"#
        ] {
            let camera = try payload(json)
            XCTAssertThrowsError(try camera.result(imageWidth: 100, imageHeight: 200), json) { error in
                guard case AIServiceError.invalidComposition = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testDegenerateAndOutOfBoundsNormalizedRectsAreRejected() {
        let invalid: [(Double, Double, Double, Double)] = [
            (0, 0, 0, 0.5), (0, 0, 0.5, 0), (0, 0, -0.1, 0.5), (0, 0, 0.5, -0.1),
            (-0.1, 0, 0.5, 0.5), (0, -0.1, 0.5, 0.5),
            (1, 0, 0.0000001, 0.5), (0, 1, 0.5, 0.0000001),
            (1.0000001, 0, 0.0000001, 0.5), (0, 1.0000001, 0.5, 0.0000001),
            (0.6, 0, 0.5, 0.5), (0, 0.6, 0.5, 0.5)
        ]
        for (x, y, width, height) in invalid {
            XCTAssertThrowsError(try AINormalizedRect(x: x, y: y, width: width, height: height).validatedRect()) { error in
                guard case AIServiceError.invalidComposition = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testNonFiniteCoordinatesAreRejected() {
        for nonFinite in [Double.nan, Double.infinity, -Double.infinity] {
            let candidates = [
                AINormalizedRect(x: nonFinite, y: 0, width: 0.5, height: 0.5),
                AINormalizedRect(x: 0, y: nonFinite, width: 0.5, height: 0.5),
                AINormalizedRect(x: 0, y: 0, width: nonFinite, height: 0.5),
                AINormalizedRect(x: 0, y: 0, width: 0.5, height: nonFinite)
            ]
            for candidate in candidates {
                XCTAssertThrowsError(try candidate.validatedRect()) { error in
                    guard case AIServiceError.invalidComposition = error else { return XCTFail("Unexpected error: \(error)") }
                }
            }
        }
    }

    func testTinyFloatingPointOvershootClipsToImageEdge() throws {
        let rect = try AINormalizedRect(x: 0.2, y: 0.3, width: 0.8000005, height: 0.7000005).validatedRect()
        assertRect(rect, CGRect(x: 0.2, y: 0.3, width: 0.8, height: 0.7))
        XCTAssertLessThanOrEqual(rect.maxX, 1)
        XCTAssertLessThanOrEqual(rect.maxY, 1)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
    }

    func testOvershootBeyondToleranceIsRejected() {
        XCTAssertThrowsError(try AINormalizedRect(x: 0.2, y: 0, width: 0.800002, height: 1).validatedRect())
        XCTAssertThrowsError(try AINormalizedRect(x: 0, y: 0.3, width: 1, height: 0.700002).validatedRect())
    }

    func testFilterRecommendationsTrimDeduplicateAndPreserveOrder() throws {
        let camera = try payload(#"{"SubAreaRectNorm":{"X":0,"Y":0,"W":1,"H":1},"AiCameraFilters":[{"FilterName":"  Film  ","Reason":"first"},{"FilterName":"film","Reason":"duplicate"},{"FilterName":" ","Reason":"blank"},{"Reason":"missing name"},{"FilterName":"Warm"}],"AiCameraFilter":{"FilterName":"FILM","Reason":"legacy duplicate"}}"#)
        let result = try camera.result(imageWidth: 100, imageHeight: 200)
        XCTAssertEqual(result.recommendations, [
            AIFilterRecommendation(filterName: "Film", reason: "first"),
            AIFilterRecommendation(filterName: "Warm", reason: "")
        ])
    }

    func testLegacySingleFilterIsIncluded() throws {
        let camera = try payload(#"{"SubAreaRectNorm":{"X":0,"Y":0,"W":1,"H":1},"AiCameraFilter":{"FilterName":"Warm","Reason":"sunlight"}}"#)
        let result = try camera.result(imageWidth: 100, imageHeight: 200)
        XCTAssertEqual(result.recommendations, [AIFilterRecommendation(filterName: "Warm", reason: "sunlight")])
    }

    func testMissingOptionalTextAndFiltersProduceEmptyValues() throws {
        let camera = try payload(#"{"SubAreaRectNorm":{"X":0,"Y":0,"W":1,"H":1}}"#)
        let result = try camera.result(imageWidth: 100, imageHeight: 200)
        XCTAssertEqual(result.reason, "")
        XCTAssertTrue(result.recommendations.isEmpty)
        XCTAssertNil(result.suggestedZoomFactor)
    }

    func testLongReasonsAreBounded() throws {
        let object: [String: Any] = [
            "SubAreaRectNorm": ["X": 0, "Y": 0, "W": 1, "H": 1],
            "ComposeReason": String(repeating: "景", count: 1100),
            "AiCameraFilter": ["FilterName": "Film", "Reason": String(repeating: "光", count: 600)]
        ]
        let camera = try JSONDecoder().decode(AICameraPayload.self, from: JSONSerialization.data(withJSONObject: object))
        let result = try camera.result(imageWidth: 100, imageHeight: 200)
        XCTAssertEqual(result.reason, String(repeating: "景", count: 1000))
        XCTAssertEqual(result.recommendations.first?.reason, String(repeating: "光", count: 500))
    }

    func testSuggestedZoomAcceptsJSONNumberOrString() throws {
        for encodedZoom in ["2.5", #""2.5""#] {
            let camera = try payload("{\"SubAreaRectNorm\":{\"X\":0,\"Y\":0,\"W\":1,\"H\":1},\"ExifFocalLength\":\(encodedZoom)}")
            let result = try camera.result(imageWidth: 100, imageHeight: 200)
            XCTAssertEqual(try XCTUnwrap(result.suggestedZoomFactor), 2.5, accuracy: 0.00000001)
        }
    }

    func testInvalidOrNullSuggestedZoomIsIgnored() throws {
        for encodedZoom in ["null", "0", "-1", #""0""#, #""-1""#, #""NaN""#, #""inf""#, #""not a number""#] {
            let camera = try payload("{\"SubAreaRectNorm\":{\"X\":0,\"Y\":0,\"W\":1,\"H\":1},\"ExifFocalLength\":\(encodedZoom)}")
            let result = try camera.result(imageWidth: 100, imageHeight: 200)
            XCTAssertNil(result.suggestedZoomFactor, encodedZoom)
        }
    }
}
