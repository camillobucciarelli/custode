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

/// spec 023 T708 / T709 — why a passkey registration ends without a passkey
/// the site knows about.
enum PasskeyRegistrationStop {
  /// The app is not running, or its vault is closed or locked.
  case appUnavailable

  /// The site does not accept ES256, the only passkey type the app creates.
  case algorithmUnsupported

  /// The vault already holds a credential the site asked to exclude.
  case excluded

  /// The app accepted the write and never reported its outcome.
  case maybeSaved
}

/// spec 023 T708 / T709 — what the extension shows when a site asks it to
/// CREATE a passkey and the ceremony stops here.
///
/// A passkey is written into the `.kdbx`, and this process has no master
/// password, so it cannot write the vault at all. It asks the running Custode
/// app to; this screen is what remains when that does not end in a passkey.
///
/// What the extension must never do instead is mint a key, seal it into its
/// own cache and answer the site "registered" in the hope the app adopts it
/// later. That is the one failure FR-020 forbids: the site would retire the
/// password for a credential the vault does not hold, and the account would
/// be lost. So the ceremony is stopped, clearly, and the site gets an ordinary
/// failure it can fall back from instead of a hung sheet.
///
/// [PasskeyRegistrationStop.maybeSaved] is the one case where the vault may
/// have changed: the write was accepted and its answer never came. Nothing is
/// rolled back, because this process cannot know whether there is anything to
/// roll back; the user is told what to check and what to delete.
struct PasskeyRegistrationUnavailableView: View {
  let relyingPartyId: String
  let userName: String
  let stop: PasskeyRegistrationStop
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "key.horizontal")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
      Text(title)
        .font(.headline)
        .multilineTextAlignment(.center)
      Text(detail)
        .font(.footnote)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
      Button(stop == .appUnavailable || stop == .algorithmUnsupported ? "Cancel" : "Close", action: onCancel)
        .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private var site: String {
    relyingPartyId.isEmpty ? "this site" : relyingPartyId
  }

  private var title: String {
    switch stop {
    case .appUnavailable:
      return "Open Custode to create this passkey"
    case .algorithmUnsupported:
      return "Custode cannot create this passkey"
    case .excluded:
      return "Passkey already in Custode"
    case .maybeSaved:
      return "Custode did not confirm the passkey"
    }
  }

  private var detail: String {
    switch stop {
    case .appUnavailable:
      return """
      Custode saves the passkey in your vault, so the app must be open and \
      the vault unlocked. Open Custode, unlock your vault, then try again.
      """
    case .algorithmUnsupported:
      return """
      \(site) does not accept the passkey type Custode creates, so Custode \
      will not tell \(site) that a passkey exists when it does not. Nothing \
      was saved in your vault.
      """
    case .excluded:
      return "Custode already holds a passkey for this account on this site."
    case .maybeSaved:
      let account = userName.isEmpty ? "" : " for \(userName)"
      return """
      The passkey may have been saved in Custode, but \(site) was not told \
      about it. If \(site) shows no passkey\(account), delete it in Custode \
      and try again.
      """
    }
  }
}

/// spec 023 T709 — shown while the extension waits for the app: first to learn
/// whether a vault is open, later while the vault is being written.
struct PasskeyRegistrationProgressView: View {
  let message: String

  var body: some View {
    VStack(spacing: 16) {
      ProgressView()
      Text(message)
        .font(.footnote)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

/// spec 023 T709 — the one decision the user makes in this extension: create
/// the passkey or not.
///
/// It names the site and the account because those are the two things the
/// user can check against what they meant to do. The replacement warning is
/// part of the same decision: what is shown here is exactly what the app is
/// then asked to do, so a passkey is never replaced without this line having
/// been on screen.
struct PasskeyRegistrationConfirmView: View {
  let relyingPartyId: String
  let userName: String
  let replaces: Bool
  let onCreate: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "key.horizontal")
        .font(.system(size: 48))
        .foregroundColor(.accentColor)
      Text("Create a passkey in Custode?")
        .font(.headline)
        .multilineTextAlignment(.center)

      VStack(alignment: .leading, spacing: 8) {
        PasskeyRegistrationDetailRow(label: "Site", value: relyingPartyId)
        PasskeyRegistrationDetailRow(
          label: "Account",
          value: userName.isEmpty ? "No account name" : userName
        )
      }
      .padding(.horizontal, 24)

      if replaces {
        Text("This replaces the passkey Custode already holds for this account")
          .font(.footnote)
          .foregroundColor(.orange)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }

      HStack(spacing: 12) {
        Button("Cancel", action: onCancel)
          .buttonStyle(.bordered)
          .keyboardShortcut(.cancelAction)
        Button("Create", action: onCreate)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

private struct PasskeyRegistrationDetailRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label)
        .font(.footnote)
        .foregroundColor(.secondary)
        .frame(width: 64, alignment: .leading)
      Text(value)
        .font(.body)
        .lineLimit(2)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
  }
}
