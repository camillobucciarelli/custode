import SwiftUI

struct CredentialListView: View {
  let credentials: [AutofillCredentialMetadata]
  let searchableCredentials: [AutofillCredentialMetadata]
  let bestMatchId: String?
  let isGlobalSearch: Bool
  let onSelect: (AutofillCredentialMetadata) -> Void
  let onCancel: () -> Void

  @State private var searchText = ""

  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        if isGlobalSearch {
          GlobalSearchHeaderView(searchText: $searchText)
          Divider()
        }

        if visibleCredentials.isEmpty {
          if isGlobalSearch {
            EmptyGlobalSearchView()
          } else {
            EmptyCredentialsView()
          }
        } else {
          List(visibleCredentials, id: \.id) { credential in
            Button {
              onSelect(credential)
            } label: {
              CredentialRowView(
                credential: credential,
                isBestMatch: credential.id == bestMatchId,
                isPossibleMatch: isGlobalSearch
              )
            }
            .buttonStyle(.plain)
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle(isGlobalSearch ? "Search Credentials" : "Credentials")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
      }
    }
  }

  private var visibleCredentials: [AutofillCredentialMetadata] {
    guard isGlobalSearch else { return credentials }
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return credentials }
    return AutofillMetadataSearch.search(searchableCredentials, query: query)
  }
}

private struct GlobalSearchHeaderView: View {
  @Binding var searchText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No match for this app or site")
        .font(.headline)
      Text("Search saved credential metadata. Passwords stay encrypted until you choose an item.")
        .font(.footnote)
        .foregroundColor(.secondary)
      TextField("Search title, username, site, app", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled(true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
  }
}

private struct EmptyGlobalSearchView: View {
  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
      Text("No credentials found")
        .font(.headline)
      Text("Try another title, username, site, or app.")
        .font(.footnote)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

private struct EmptyCredentialsView: View {
  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "key.slash")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
      Text("No matching credentials")
        .font(.headline)
      Text("Open Custode, unlock your vault, and publish the encrypted AutoFill cache before filling.")
        .font(.footnote)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

private struct CredentialRowView: View {
  let credential: AutofillCredentialMetadata
  let isBestMatch: Bool
  let isPossibleMatch: Bool

  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(Color.accentColor.opacity(0.15))
        .frame(width: 40, height: 40)
        .overlay {
          Text(initial)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.accentColor)
        }

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(title)
            .font(.body)
            .foregroundColor(.primary)
            .lineLimit(1)
          if isBestMatch {
            CredentialBadgeView(
              text: "Best match",
              foregroundColor: .accentColor,
              backgroundColor: Color.accentColor.opacity(0.12)
            )
          } else if isPossibleMatch {
            CredentialBadgeView(
              text: "Possible match — not linked",
              foregroundColor: .orange,
              backgroundColor: Color.orange.opacity(0.14)
            )
          }
        }

        if !credential.username.isEmpty {
          Text(credential.username)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }

        if !credential.displayService.isEmpty {
          Text(credential.displayService)
            .font(.caption2)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundColor(.secondary.opacity(0.5))
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  private var title: String {
    credential.title.isEmpty ? "Untitled" : credential.title
  }

  private var initial: String {
    String(title.prefix(1)).uppercased()
  }
}

private struct CredentialBadgeView: View {
  let text: String
  let foregroundColor: Color
  let backgroundColor: Color

  var body: some View {
    Text(text)
      .font(.caption2)
      .fontWeight(.medium)
      .foregroundColor(foregroundColor)
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(backgroundColor)
      .clipShape(Capsule())
  }
}

/// spec 023 T708 — what the extension shows when a site asks it to CREATE a
/// passkey.
///
/// The decision this screen implements: a passkey is created by the Custode
/// app, never by this extension. The extension is a plugin of the app and
/// holds no logic the app does not know about — and here that is not a
/// preference but the only correct behaviour. Creating a credential means
/// writing it into the `.kdbx`, and this process has no master password, so it
/// cannot write the vault at all. What it *could* do is mint a key, seal it
/// into its own cache and answer the site "registered" in the hope the app
/// adopts it later. That is the one failure FR-020 forbids: the site would
/// retire the password for a credential the vault does not hold, and the
/// account would be lost.
///
/// So the ceremony is refused, clearly and immediately, and the site gets an
/// ordinary failure it can fall back from instead of a hung sheet. Nothing is
/// staged, nothing is half-written, and the user is told where creating a
/// passkey does work today.
struct PasskeyRegistrationUnavailableView: View {
  let relyingPartyId: String
  let userName: String
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "key.horizontal")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
      Text("Create this passkey in Custode")
        .font(.headline)
        .multilineTextAlignment(.center)
      Text(detail)
        .font(.footnote)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
      Button("Cancel", action: onCancel)
        .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private var detail: String {
    let site = relyingPartyId.isEmpty ? "this site" : relyingPartyId
    let account = userName.isEmpty ? "" : " for \(userName)"
    return """
    A passkey is written into your vault, which only the Custode app can \
    open. This AutoFill extension cannot write it, so it will not tell \(site) \
    that a passkey exists when it does not.

    To add a passkey\(account), open Custode on a computer, unlock the vault, \
    and register on \(site) from a browser with the Custode extension.
    """
  }
}
