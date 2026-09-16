import XCTest
@testable import NightBlood

final class CodexRemoteEnrolmentDiagnosticTests: XCTestCase {
    func testAllowlistedCodeIsKeptButArbitraryResponseFieldsAreNot() {
        let body = Data(#"{"error":{"code":"access_denied","message":"private account and token text"},"access_token":"private-value"}"#.utf8)
        let diagnostic = CodexRemoteEnrolmentRejection(
            stage: .start, response: .init(statusCode: 403, body: body)
        )
        XCTAssertEqual(diagnostic.serviceCode, .accessDenied)
        XCTAssertEqual(diagnostic.responseKind, .json)
        XCTAssertTrue(diagnostic.description.contains("enrolment start"))
        XCTAssertTrue(diagnostic.description.contains("before device-key creation"))
        XCTAssertFalse(diagnostic.description.contains("private"))
    }

    func testUnknownCodeIsNotEchoed() {
        let diagnostic = CodexRemoteEnrolmentRejection(
            stage: .stepUpToken,
            response: .init(statusCode: 403, body: Data(#"{"code":"private_value_not_to_display"}"#.utf8))
        )
        XCTAssertNil(diagnostic.serviceCode)
        XCTAssertFalse(diagnostic.description.contains("private_value"))
        XCTAssertTrue(diagnostic.description.contains("additional authorisation token exchange"))
        XCTAssertFalse(diagnostic.description.contains("before device-key creation"))
    }

    func testHTMLRefusalDoesNotClaimAccountAccessFailure() {
        let diagnostic = CodexRemoteEnrolmentRejection(
            stage: .start,
            response: .init(statusCode: 403, body: Data(" \n<!DOCTYPE html><html>private diagnostic</html>".utf8))
        )
        XCTAssertEqual(diagnostic.responseKind, .html)
        XCTAssertTrue(diagnostic.description.contains("does not establish an account-access failure"))
        XCTAssertFalse(diagnostic.description.contains("private diagnostic"))
    }

    func testEmptyAndMalformedBodiesAreNotEchoed() {
        for (body, kind) in [(Data(), CodexRemoteEnrolmentRejection.ResponseKind.empty),
                             (Data("private malformed response".utf8), .other)] {
            let diagnostic = CodexRemoteEnrolmentRejection(
                stage: .start, response: .init(statusCode: 403, body: body)
            )
            XCTAssertEqual(diagnostic.responseKind, kind)
            XCTAssertFalse(diagnostic.description.contains("private"))
        }
    }

    func testRejectedEnrolmentStartIsSentOnlyOnce() async {
        let transport = RejectedEnrolmentDiagnosticTransport()
        let account = CodexRemoteAccountContext(
            accessToken: "test-token", accountID: "test-account", accountUserID: "test-user",
            tokenUserID: nil, expiresAt: 4_000_000_000
        )
        let client = CodexRemoteAuthenticatedRESTClient(account: account, transport: transport)
        do {
            _ = try await client.enrolStart()
            XCTFail("Expected refusal")
        } catch CodexRemoteEnrolmentError.enrolmentRequestRejected(let diagnostic) {
            XCTAssertEqual(diagnostic.stage, .start)
            XCTAssertEqual(diagnostic.statusCode, 403)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let count = await transport.requestCount
        XCTAssertEqual(count, 1)
    }
}

private actor RejectedEnrolmentDiagnosticTransport: CodexRemoteHTTPTransport {
    private(set) var requestCount = 0

    func send(_ request: CodexRemoteHTTPRequest) async throws -> CodexRemoteHTTPResponse {
        requestCount += 1
        return .init(statusCode: 403, body: Data(#"{"error":{"code":"access_denied"}}"#.utf8))
    }
}
