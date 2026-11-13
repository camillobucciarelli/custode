import AuthenticationServices
import OSLog
import SwiftUI

private let log = Logger(
  subsystem: "dev.camillobucciarelli.kdbxKeyVault.CredentialProviderExtension",
  category: "ext"
)

private struct PendingAssociationContext {
  let serviceIdentifiers: [ASCredentialServiceIdentifier]
}

final class CredentialProviderViewController: ASCredentialProviderViewController {
  private let store = SharedAutofillStore()
  private var hostingController: UIHostingController<CredentialListView>?

  /// spec 023 T304 — set while this invocation is answering a passkey sign-in
  /// rather than a password fill. Selecting a record then completes an
  /// assertion instead of handing back an `ASPasswordCredential`.
  private var passkeyRequest: ASPasskeyCredentialRequest?

  /// spec 023 T708 — hosts the registration refusal screen. Separate from
  /// [hostingController] because the two root views are different types and a
  /// single invocation only ever shows one of them.
  private var registrationHost: UIHostingController<PasskeyRegistrationUnavailableView>?

  override func viewDidLoad() {
    super.viewDidLoad()
    store.wipeLegacyPlaintextArtifacts(reason: "viewDidLoad")
    log.info("viewDidLoad")
  }

  // MARK: - Credential list (user explicitly opened the extension)

  override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    log.info("prepareCredentialList serviceIdentifierCount=\(serviceIdentifiers.count, privacy: .public)")
    showCredentialList(
      reason: "credential list",
      serviceIdentifiers: serviceIdentifiers,
      preferredRecordIdentifier: nil
    )
  }

  /// spec 023 T304 / FR-017 — the list of passkeys that can answer this
  /// request: the relying party must match, and `allowedCredentials`, when
  /// the site sent one, must name the credential.
  ///
  /// An empty list cancels with `credentialIdentityNotFound` rather than
  /// showing an empty sheet. The system then falls through to whatever else
  /// can answer, which is what the user wants when Custode has nothing.
  @available(iOS 17.0, *)
  override func prepareCredentialList(
    for serviceIdentifiers: [ASCredentialServiceIdentifier],
    requestParameters: ASPasskeyCredentialRequestParameters
  ) {
    let rpId = requestParameters.relyingPartyIdentifier
    log.info("prepareCredentialList(passkey) rpId=\(rpId, privacy: .public)")
    store.wipeLegacyPlaintextArtifacts(reason: "passkey credential list")

    let allowed = Set(requestParameters.allowedCredentials.map { $0.base64URLEncodedString })
    let matches = store.readCredentialMetadata().filter { metadata in
      metadata.passkeys.contains { passkey in
        passkey.rpId.caseInsensitiveCompare(rpId) == .orderedSame
          && (allowed.isEmpty || allowed.contains(passkey.credentialId))
      }
    }
    guard !matches.isEmpty else {
      log.info("no passkey for rpId=\(rpId, privacy: .public)")
      cancelWithError(.credentialIdentityNotFound)
      return
    }

    let rootView = CredentialListView(
      credentials: matches,
      searchableCredentials: matches,
      bestMatchId: matches.first?.id,
      isGlobalSearch: false,
      onSelect: { [weak self] metadata in
        self?.completePasskeyAssertion(for: metadata, rpId: rpId)
      },
      onCancel: { [weak self] in
        log.info("user cancelled passkey list")
        self?.cancelWithError(.userCanceled)
      }
    )
    install(rootView: rootView)
  }

  // MARK: - Silent fill

  override func provideCredentialWithoutUserInteraction(
    for credentialIdentity: ASPasswordCredentialIdentity
  ) {
    log.info("provideCredentialWithoutUserInteraction(identity) requires user interaction")
    store.wipeLegacyPlaintextArtifacts(reason: "silent fill")

    // This milestone deliberately avoids decrypting/filling outside an explicit
    // extension UI selection. The cache is encrypted, but the extension has no
    // reliable recent vault/user-presence context in this callback.
    cancelWithError(.userInteractionRequired)
  }

  @available(iOS 17.0, *)
  override func provideCredentialWithoutUserInteraction(
    for credentialRequest: any ASCredentialRequest
  ) {
    log.info("provideCredentialWithoutUserInteraction(any) type=\(String(describing: type(of: credentialRequest)), privacy: .public)")
    // spec 023 FR-015: a passkey is never used without the user present, and
    // the answer does not depend on anything this callback could inspect —
    // it is always "ask me". The system re-invokes the interactive path.
    if credentialRequest is ASPasskeyCredentialRequest {
      log.info("passkey silent request → userInteractionRequired")
      cancelWithError(.userInteractionRequired)
      return
    }
    guard let passwordRequest = credentialRequest as? ASPasswordCredentialRequest,
          let identity = passwordRequest.credentialIdentity as? ASPasswordCredentialIdentity else {
      log.error("unsupported credential request → .failed")
      cancelWithError(.failed, message: "Unsupported credential type")
      return
    }

    provideCredentialWithoutUserInteraction(for: identity)
  }

  // MARK: - Interactive fill

  override func prepareInterfaceToProvideCredential(
    for credentialIdentity: ASPasswordCredentialIdentity
  ) {
    log.info("prepareInterfaceToProvideCredential(identity)")
    showCredentialList(
      reason: "interactive fill",
      serviceIdentifiers: [credentialIdentity.serviceIdentifier],
      preferredRecordIdentifier: credentialIdentity.recordIdentifier
    )
  }

  @available(iOS 17.0, *)
  override func prepareInterfaceToProvideCredential(
    for credentialRequest: any ASCredentialRequest
  ) {
    log.info("prepareInterfaceToProvideCredential(any) type=\(String(describing: type(of: credentialRequest)), privacy: .public)")
    if let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest {
      prepareInterfaceToProvidePasskey(passkeyRequest)
      return
    }
    guard let passwordRequest = credentialRequest as? ASPasswordCredentialRequest,
          let identity = passwordRequest.credentialIdentity as? ASPasswordCredentialIdentity else {
      log.error("unsupported interactive credential request → .failed")
      cancelWithError(.failed, message: "Unsupported credential type")
      return
    }

    prepareInterfaceToProvideCredential(for: identity)
  }

  // MARK: - Registration (spec 023 T708)

  /// spec 023 T708 / FR-020 — a registration never happens in this process.
  ///
  /// The decision, in one line: registration always goes through the app, and
  /// the extension implements no step of it the app does not perform. The
  /// reasoning is on [PasskeyRegistrationUnavailableView]; the mechanics are
  /// that this process has no master password and therefore cannot write the
  /// `.kdbx`, so the only alternative to refusing would be telling the site a
  /// credential exists before the vault holds one.
  ///
  /// The refusal is explicit rather than an unimplemented override: without it
  /// the system presents this extension's empty sheet and the ceremony hangs
  /// until the user backs out, with no explanation anywhere.
  @available(iOS 17.0, *)
  override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
    let identity = (registrationRequest as? ASPasskeyCredentialRequest)?
      .credentialIdentity as? ASPasskeyCredentialIdentity
    let rpId = identity?.relyingPartyIdentifier ?? ""
    let userName = identity?.userName ?? ""
    log.info("prepareInterface(forPasskeyRegistration) rpId=\(rpId, privacy: .public) → refused, the app is the only writer")

    installRegistrationRefusal(relyingPartyId: rpId, userName: userName)
  }

  private func installRegistrationRefusal(relyingPartyId: String, userName: String) {
    let rootView = PasskeyRegistrationUnavailableView(
      relyingPartyId: relyingPartyId,
      userName: userName,
      onCancel: { [weak self] in
        log.info("registration refusal dismissed by the user")
        // `.failed` and not `.userCanceled`: the user did not decline the
        // passkey, this provider cannot serve it. The distinction is what lets
        // the browser offer another provider instead of treating the ceremony
        // as abandoned.
        self?.cancelWithError(.failed, message: "Custode creates passkeys in the app, not in AutoFill.")
      }
    )

    if let registrationHost {
      registrationHost.rootView = rootView
      return
    }
    let host = UIHostingController(rootView: rootView)
    registrationHost = host
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
  }

  override func prepareInterfaceForExtensionConfiguration() {
    log.info("prepareInterfaceForExtensionConfiguration")
    store.wipeLegacyPlaintextArtifacts(reason: "extension configuration")
    extensionContext.completeExtensionConfigurationRequest()
  }

  // MARK: - UI

  private func showCredentialList(
    reason: String,
    serviceIdentifiers: [ASCredentialServiceIdentifier],
    preferredRecordIdentifier: String?
  ) {
    store.wipeLegacyPlaintextArtifacts(reason: reason)

    let allCredentials = store.readCredentialMetadata()
    let credentials: [AutofillCredentialMetadata]
    let searchableCredentials: [AutofillCredentialMetadata]
    let bestMatchId: String?
    let isGlobalSearch: Bool

    if let preferredRecordIdentifier {
      guard let exact = allCredentials.first(where: { $0.id == preferredRecordIdentifier }) else {
        log.error("preferred credential not found reason=\(reason, privacy: .public)")
        cancelWithError(.credentialIdentityNotFound)
        return
      }
      credentials = [exact]
      searchableCredentials = [exact]
      bestMatchId = preferredRecordIdentifier
      isGlobalSearch = false
    } else {
      let filtered = store.filteredCredentialMetadata(
        allCredentials,
        for: serviceIdentifiers
      )
      let filteredCredentials = filtered.credentials
      isGlobalSearch = !serviceIdentifiers.isEmpty && filteredCredentials.isEmpty && !allCredentials.isEmpty
      if isGlobalSearch {
        let possibleMatches = AutofillMetadataSearch.possibleMatches(
          in: allCredentials,
          for: serviceIdentifiers
        )
        credentials = possibleMatches.isEmpty ? allCredentials : possibleMatches
        searchableCredentials = allCredentials
      } else {
        credentials = filteredCredentials
        searchableCredentials = filteredCredentials
      }
      bestMatchId = isGlobalSearch ? nil : filtered.bestMatchId
    }

    let pendingAssociationContext: PendingAssociationContext?
    if isGlobalSearch {
      pendingAssociationContext = PendingAssociationContext(serviceIdentifiers: serviceIdentifiers)
    } else {
      pendingAssociationContext = nil
    }

    log.info(
      "showCredentialList reason=\(reason, privacy: .public) total=\(allCredentials.count, privacy: .public) shown=\(credentials.count, privacy: .public) searchable=\(searchableCredentials.count, privacy: .public) globalSearch=\(isGlobalSearch, privacy: .public) encryptedCacheExists=\(self.store.encryptedCredentialCacheExists(), privacy: .public)"
    )

    let rootView = CredentialListView(
      credentials: credentials,
      searchableCredentials: searchableCredentials,
      bestMatchId: bestMatchId,
      isGlobalSearch: isGlobalSearch,
      onSelect: { [weak self] metadata in
        self?.completeCredentialSelection(
          metadata,
          pendingAssociationContext: pendingAssociationContext
        )
      },
      onCancel: { [weak self] in
        log.info("user cancelled")
        self?.cancelWithError(.userCanceled)
      }
    )

    install(rootView: rootView)
  }

  private func install(rootView: CredentialListView) {
    if let hostingController {
      hostingController.rootView = rootView
      return
    }

    let host = UIHostingController(rootView: rootView)
    hostingController = host
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
    log.info("host controller attached")
  }

  // MARK: - Fill completion

  private func completeCredentialSelection(
    _ metadata: AutofillCredentialMetadata,
    pendingAssociationContext: PendingAssociationContext? = nil
  ) {
    do {
      let secret = try store.readCredentialSecret(id: metadata.id)
      let user = secret.username.isEmpty ? metadata.username : secret.username
      let credential = ASPasswordCredential(user: user, password: secret.password)
      if let pendingAssociationContext {
        store.savePendingAssociation(
          for: metadata,
          requestedServiceIdentifiers: pendingAssociationContext.serviceIdentifiers
        )
      }
      log.info("completeCredentialSelection succeeded")
      extensionContext.completeRequest(
        withSelectedCredential: credential,
        completionHandler: nil
      )
    } catch SharedAutofillStoreError.credentialNotFound {
      log.error("completeCredentialSelection credential not found")
      cancelWithError(.credentialIdentityNotFound)
    } catch {
      log.error("completeCredentialSelection failed error=\(String(describing: type(of: error)), privacy: .public)")
      cancelWithError(.failed)
    }
  }

  // MARK: - Passkey assertion (spec 023 T304)

  /// The system already knows which credential it wants — the identity it
  /// registered — so there is nothing to choose. What remains is the user
  /// proving they are present, every single time (FR-015).
  @available(iOS 17.0, *)
  private func prepareInterfaceToProvidePasskey(_ request: ASPasskeyCredentialRequest) {
    store.wipeLegacyPlaintextArtifacts(reason: "passkey fill")
    guard let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
          let recordIdentifier = identity.recordIdentifier else {
      log.error("passkey request without a record identifier")
      cancelWithError(.credentialIdentityNotFound)
      return
    }
    passkeyRequest = request
    completePasskeyAssertion(
      recordIdentifier: recordIdentifier,
      rpId: identity.relyingPartyIdentifier,
      credentialId: identity.credentialID.base64URLEncodedString,
      clientDataHash: request.clientDataHash
    )
  }

  /// The user picked a record from the passkey list. The request that brought
  /// us here carries the client data hash to sign.
  @available(iOS 17.0, *)
  private func completePasskeyAssertion(
    for metadata: AutofillCredentialMetadata,
    rpId: String
  ) {
    guard let request = passkeyRequest else {
      // Reached from `prepareCredentialList(requestParameters:)`, where the
      // system has not handed over a request to complete. Nothing can be
      // signed from here, and pretending otherwise would hang the sheet.
      log.error("passkey selection without a pending request")
      cancelWithError(.failed, message: "No passkey request to answer")
      return
    }
    let credentialId = metadata.passkeys.first {
      $0.rpId.caseInsensitiveCompare(rpId) == .orderedSame
    }?.credentialId
    completePasskeyAssertion(
      recordIdentifier: metadata.id,
      rpId: rpId,
      credentialId: credentialId,
      clientDataHash: request.clientDataHash
    )
  }

  /// Authenticate, unseal, sign, complete. In that order, with no step
  /// skippable: the authentication is what FR-015 requires, and the secret is
  /// read only after it succeeds, so a cancelled prompt never unseals
  /// anything.
  @available(iOS 17.0, *)
  private func completePasskeyAssertion(
    recordIdentifier: String,
    rpId: String,
    credentialId: String?,
    clientDataHash: Data
  ) {
    PasskeyUserPresence.require(
      reason: "Sign in to \(rpId)"
    ) { [weak self] authenticated in
      guard let self else { return }
      guard authenticated else {
        log.info("passkey assertion declined by the user")
        self.cancelWithError(.userCanceled)
        return
      }
      do {
        let secretRecord = try self.store.readCredentialSecret(id: recordIdentifier)
        guard let secret = secretRecord.passkeys.first(where: { passkey in
          passkey.rpId.caseInsensitiveCompare(rpId) == .orderedSame
            && (credentialId == nil || passkey.credentialId == credentialId)
        }) else {
          log.error("passkey not in the sealed record rpId=\(rpId, privacy: .public)")
          self.cancelWithError(.credentialIdentityNotFound)
          return
        }
        let assertion = try PasskeyAssertionBuilder.assert(
          secret: secret,
          clientDataHash: clientDataHash
        )
        let credential = ASPasskeyAssertionCredential(
          userHandle: assertion.userHandle,
          relyingParty: secret.rpId,
          signature: assertion.signature,
          clientDataHash: clientDataHash,
          authenticatorData: assertion.authenticatorData,
          credentialID: assertion.credentialID
        )
        log.info("passkey assertion completed rpId=\(rpId, privacy: .public)")
        self.extensionContext.completeAssertionRequest(using: credential)
      } catch SharedAutofillStoreError.credentialNotFound {
        log.error("passkey record not found")
        self.cancelWithError(.credentialIdentityNotFound)
      } catch {
        log.error("passkey assertion failed error=\(String(describing: type(of: error)), privacy: .public)")
        self.cancelWithError(.failed)
      }
    }
  }

  // MARK: - Error helpers

  private func cancelWithError(
    _ code: ASExtensionError.Code,
    message: String? = nil
  ) {
    log.info("cancelWithError code=\(code.rawValue, privacy: .public) hasMessage=\(message != nil, privacy: .public)")
    let userInfo: [String: Any]? = message.map { [NSLocalizedDescriptionKey: $0] }
    extensionContext.cancelRequest(
      withError: NSError(
        domain: ASExtensionErrorDomain,
        code: code.rawValue,
        userInfo: userInfo
      )
    )
  }
}
