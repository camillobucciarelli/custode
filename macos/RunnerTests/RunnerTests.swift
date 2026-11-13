import AuthenticationServices
import Cocoa
import FlutterMacOS
import XCTest
@testable import Custode

class RunnerTests: XCTestCase {

  func testPossibleMatchesUseTargetTokensWithoutGenericWords() {
    let entries = [
      makeMetadata(
        id: "acme",
        title: "Acme Admin Portal",
        displayService: "vault.acmecorp.io",
        serviceIdentifiers: [
          AutofillServiceIdentifier(type: .domain, value: "vault.acmecorp.io"),
        ]
      ),
      makeMetadata(
        id: "github",
        title: "GitHub",
        displayService: "github.com",
        serviceIdentifiers: [
          AutofillServiceIdentifier(type: .domain, value: "github.com"),
        ]
      ),
    ]

    let service = ASCredentialServiceIdentifier(
      identifier: "https://login.acme-mobile.com",
      type: .URL
    )

    XCTAssertEqual(
      AutofillMetadataSearch.targetTokens(from: [
        AutofillServiceIdentifier(type: .url, value: "https://login.acme-mobile.com"),
      ]),
      ["acme"]
    )
    XCTAssertEqual(
      AutofillMetadataSearch.possibleMatches(in: entries, for: [service]).map(\.id),
      ["acme"]
    )
  }

  func testManualSearchMatchesSubstringMetadataAndLimitsSingleCharacterQuery() {
    let entries = [
      makeMetadata(
        id: "acme",
        title: "Acme Admin Portal",
        username: "owner@example.com",
        displayService: "vault.acmecorp.io",
        serviceIdentifiers: [
          AutofillServiceIdentifier(type: .url, value: "https://vault.acmecorp.io"),
        ]
      ),
      makeMetadata(id: "zeta", title: "Zeta", displayService: "zeta.example.com"),
    ]

    XCTAssertEqual(AutofillMetadataSearch.search(entries, query: "corp").map(\.id), ["acme"])
    XCTAssertEqual(AutofillMetadataSearch.search(entries, query: "ner@example").map(\.id), ["acme"])
    XCTAssertEqual(AutofillMetadataSearch.search(entries, query: "z").map(\.id), ["zeta"])

    let manyEntries = (0..<30).map { index in
      makeMetadata(id: "alpha-\(index)", title: "Alpha \(index)")
    }
    XCTAssertEqual(
      AutofillMetadataSearch.search(manyEntries, query: "a").count,
      AutofillMetadataSearch.oneCharacterManualSearchLimit
    )
  }

  private func makeMetadata(
    id: String,
    title: String,
    username: String = "",
    displayService: String = "",
    serviceIdentifiers: [AutofillServiceIdentifier] = []
  ) -> AutofillCredentialMetadata {
    AutofillCredentialMetadata(
      id: id,
      title: title,
      username: username,
      displayService: displayService,
      serviceIdentifiers: serviceIdentifiers
    )
  }

}
