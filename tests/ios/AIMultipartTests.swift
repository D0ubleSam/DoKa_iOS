import XCTest
@testable import Doka

final class AIMultipartTests: XCTestCase {
    func testMultipartPreservesBinaryJPEGAndFramesPartsWithCRLF() {
        // Calling a static encoder does not instantiate AIService.shared or use Keychain/network.
        let jpeg = Data([0xff, 0xd8, 0xff, 0x00, 0x80, 0x0d, 0x0a, 0xff, 0xd9])
        let actual = AIService.multipart(fields: ["language": "ZH", "ai_filter": "on"],
                                         jpeg: jpeg, filename: "frame.jpg", boundary: "TestBoundary")
        var expected = Data((
            "--TestBoundary\r\n" +
            "Content-Disposition: form-data; name=\"ai_filter\"\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n\r\non\r\n" +
            "--TestBoundary\r\n" +
            "Content-Disposition: form-data; name=\"language\"\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n\r\nZH\r\n" +
            "--TestBoundary\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"frame.jpg\"\r\n" +
            "Content-Type: image/jpeg\r\n\r\n"
        ).utf8)
        expected.append(jpeg)
        expected.append(Data("\r\n--TestBoundary--\r\n".utf8))
        XCTAssertEqual(actual, expected)
    }

    func testMultipartEncodesUnicodeTextAsUTF8() {
        let actual = AIService.multipart(fields: ["description": "构图"], jpeg: Data([0xff, 0xd8, 0xff]),
                                         filename: "frame.jpg", boundary: "UTF8Boundary")
        XCTAssertNotNil(actual.range(of: Data("charset=utf-8\r\n\r\n构图\r\n".utf8)))
        XCTAssertTrue(actual.suffix(Data("\r\n--UTF8Boundary--\r\n".utf8).count)
            .elementsEqual(Data("\r\n--UTF8Boundary--\r\n".utf8)))
    }
}
