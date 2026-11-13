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

final class MacCredentialProviderViewController: ASCredentialProviderViewController {
  private let store = SharedAutofillStore()
  private var hostingController: NSHostingController<CredentialListView>?

  /// spec 023 T304 — set while this invocation is answering a passkey sign-in
  /// rather than a password fill. Selecting a record then completes an
  /// assertion instead of handing back an `ASPasswordCredential`.
  private var passkeyRequest: ASPasskeyCredentialRequest?

  /// spec 023 T708 / T709 — hosts the registration screens (waiting, refusal,
  /// confirmation). Separate from [hostingController] because the root views
  /// are different types and a single invocation only ever shows one flow.
  private var registrationHost: NSHostingController<AnyView>?

  /// spec 023 T709 — talks to the running app, the only process that can
  /// write the vault.
  private let registrationClient = PasskeyRegistrationClient()

  /// Set from the moment the user presses Create until the ceremony ends, so a
  /// second press cannot start a second write.
  private var registrationCommitStarted = false

  override func viewDidLoad() {
    super.viewDidLoad()
    store.wipeLegacyPlaintextArtifacts(reason: "viewDidLoad")
    log.info("viewDidLoad")
  }

  // MARK: - Credential list

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
  /// showing an empty sheet, so the system falls through to whatever else
  /// can answer.
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
    cancelWithError(.userInteractionRequired)
  }

  override func provideCredentialWithoutUserInteraction(
    for credentialRequest: any ASCredentialRequest
  ) {
    log.info("provideCredentialWithoutUserInteraction(any) type=\(String(describing: type(of: credentialRequest)), privacy: .public)")
    // spec 023 FR-015: a passkey is never used without the user present, and
    // the answer does not depend on anything this callback could inspect.
    if credentialRequest is ASPasskeyCredentialRequest {
      log.info("passkey silent request → userInteractionRequired")
      cancelWithError(.userInteractionRequired)
      return
    }
    guard let passwordRequest = credentialRequest as? ASPasswordCredentialRequest,
          let identity = passwordRequest.credentialIdentity as? ASPasswordCredentialIdentity else {
      log.error("unsupported credential request → .failed")
      cancelWithError(.failed)
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
      cancelWithError(.failed)
      return
    }

    prepareInterfaceToProvideCredential(for: identity)
  }

  // MARK: - Registration (spec 023 T708 / T709)

  /// spec 023 T709 / FR-020 — a passkey is created by the running app and
  /// confirmed here.
  ///
  /// This process has no master password, so it cannot write the `.kdbx` and
  /// never mints a key. What it owns is the part only it can do: showing the
  /// user what is about to be created and proving they are present. The app
  /// then writes the vault and returns the public half, and the site is told
  /// "registered" only after that write has completed. Every other outcome
  /// cancels the request; there is no path that completes without `done`.
  ///
  /// The request is stopped before any confirmation when the site does not
  /// accept ES256 (the only algorithm the app creates), when the app cannot
  /// write right now (not running, no vault open, vault locked), and when the
  /// vault already holds a credential the site excluded.
  ///
  /// Stopping is explicit rather than an unimplemented override: without it
  /// the system presents this extension's empty sheet and the ceremony hangs
  /// until the user backs out, with no explanation anywhere.
  @available(macOS 14.0, *)
  override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
    store.wipeLegacyPlaintextArtifacts(reason: "passkey registration")
    let request = registrationRequest as? ASPasskeyCredentialRequest
    let identity = request?.credentialIdentity as? ASPasskeyCredentialIdentity
    let rpId = identity?.relyingPartyIdentifier ?? ""
    let userName = identity?.userName ?? ""

    guard let request, let identity, !rpId.isEmpty else {
      log.error("prepareInterface(forPasskeyRegistration) without a passkey identity → stopped")
      installRegistrationStop(.algorithmUnsupported, relyingPartyId: rpId, userName: userName)
      return
    }
    guard request.supportedAlgorithms.contains(where: { $0 == .ES256 }) else {
      log.info("prepareInterface(forPasskeyRegistration) rpId=\(rpId, privacy: .public) → stopped, ES256 not accepted")
      installRegistrationStop(.algorithmUnsupported, relyingPartyId: rpId, userName: userName)
      return
    }

    // WebAuthn `excludeCredentials`. The system only hands the list over from
    // macOS 15; on macOS 14 there is nothing to check against.
    var excludedCredentialIDs: [Data] = []
    if #available(macOS 15.0, *) {
      excludedCredentialIDs = Self.boundedExcludedCredentialIDs(
        (request.excludedCredentials ?? []).map { $0.credentialID }
      )
    }

    log.info("prepareInterface(forPasskeyRegistration) rpId=\(rpId, privacy: .public) excludedCount=\(excludedCredentialIDs.count, privacy: .public) → asking the app")
    registrationCommitStarted = false
    installRegistration(AnyView(PasskeyRegistrationProgressView(message: "Checking Custode…")))

    let userHandle = identity.userHandle
    let clientDataHash = request.clientDataHash
    registrationClient.prepare(
      rpId: rpId,
      userHandle: userHandle,
      excludedCredentialIDs: excludedCredentialIDs
    ) { [weak self] outcome in
      guard let self else { return }
      switch outcome {
      case .appUnavailable:
        log.info("registration stopped: the app has no unlocked vault to write")
        self.installRegistrationStop(.appUnavailable, relyingPartyId: rpId, userName: userName)
      case .excluded:
        log.info("registration stopped: the vault holds an excluded credential")
        self.installRegistrationStop(.excluded, relyingPartyId: rpId, userName: userName)
      case .ready(let replaces, let nonce):
        log.info("registration ready replaces=\(replaces, privacy: .public)")
        self.installRegistrationConfirmation(
          rpId: rpId,
          userName: userName,
          userHandle: userHandle,
          clientDataHash: clientDataHash,
          replaces: replaces,
          nonce: nonce
        )
      }
    }
  }

  /// The excluded list as it fits in one message. A credential id is at most
  /// 1023 bytes in WebAuthn and usually 16 to 64; the bounds keep a hostile
  /// list from pushing the request past the message size limit, at the price
  /// of not checking ids beyond them.
  private static func boundedExcludedCredentialIDs(_ ids: [Data]) -> [Data] {
    var kept: [Data] = []
    var budget = 6 * 1024
    for id in ids where !id.isEmpty && id.count <= 1023 {
      guard kept.count < 64, id.count <= budget else { break }
      budget -= id.count
      kept.append(id)
    }
    return kept
  }

  private func installRegistrationStop(
    _ stop: PasskeyRegistrationStop,
    relyingPartyId: String,
    userName: String
  ) {
    let rootView = PasskeyRegistrationUnavailableView(
      relyingPartyId: relyingPartyId,
      userName: userName,
      stop: stop,
      onCancel: { [weak self] in
        log.info("registration stop screen dismissed by the user")
        // Never `.userCanceled`: the user did not decline the passkey, this
        // provider could not serve it. The distinction is what lets the
        // browser offer another provider instead of treating the ceremony as
        // abandoned.
        switch stop {
        case .appUnavailable:
          self?.cancelWithError(.failed, message: "Open Custode, unlock your vault, then try again.")
        case .algorithmUnsupported:
          self?.cancelWithError(.failed, message: "The site does not accept the passkey type Custode creates.")
        case .excluded:
          if #available(macOS 15.0, *) {
            self?.cancelWithError(
              .matchedExcludedCredential,
              message: "Custode already holds a passkey for this account on this site."
            )
          } else {
            self?.cancelWithError(
              .failed,
              message: "Custode already holds a passkey for this account on this site."
            )
          }
        case .maybeSaved:
          self?.cancelWithError(.failed, message: "Custode did not confirm that the passkey was saved.")
        }
      }
    )
    installRegistration(AnyView(rootView))
  }

  private func installRegistrationConfirmation(
    rpId: String,
    userName: String,
    userHandle: Data,
    clientDataHash: Data,
    replaces: Bool,
    nonce: String
  ) {
    let rootView = PasskeyRegistrationConfirmView(
      relyingPartyId: rpId,
      userName: userName,
      replaces: replaces,
      onCreate: { [weak self] in
        self?.createPasskey(
          rpId: rpId,
          userName: userName,
          userHandle: userHandle,
          clientDataHash: clientDataHash,
          replaces: replaces,
          nonce: nonce
        )
      },
      onCancel: { [weak self] in
        log.info("registration declined by the user")
        self?.cancelWithError(.userCanceled)
      }
    )
    installRegistration(AnyView(rootView))
  }

  /// Authenticate, ask the app to write, complete. In that order: the app is
  /// asked to write only after the device owner check succeeds, every time,
  /// and the ceremony completes only after the app reports the vault holds the
  /// passkey.
  ///
  /// `replaces` is the value that was on screen when the user pressed Create.
  /// If the vault changed in between, the app answers `alreadyExists` rather
  /// than replacing a passkey the user was not warned about.
  ///
  /// `nonce` is what the app handed out with that confirmation. It is good
  /// for one `commit` and for two minutes; a confirmation left open longer
  /// than that fails, and the user starts again.
  private func createPasskey(
    rpId: String,
    userName: String,
    userHandle: Data,
    clientDataHash: Data,
    replaces: Bool,
    nonce: String
  ) {
    guard !registrationCommitStarted else { return }
    registrationCommitStarted = true

    PasskeyUserPresence.require(
      reason: "Create a passkey for \(rpId)"
    ) { [weak self] authenticated in
      guard let self else { return }
      guard authenticated else {
        log.info("passkey registration declined at authentication")
        self.cancelWithError(.userCanceled)
        return
      }
      self.installRegistration(AnyView(PasskeyRegistrationProgressView(message: "Saving the passkey in Custode…")))
      self.registrationClient.commit(
        rpId: rpId,
        username: userName,
        userHandle: userHandle,
        replaceExisting: replaces,
        nonce: nonce
      ) { [weak self] outcome in
        guard let self else { return }
        switch outcome {
        case .done(let credentialID, let attestationObject):
          let credential = ASPasskeyRegistrationCredential(
            relyingParty: rpId,
            clientDataHash: clientDataHash,
            credentialID: credentialID,
            attestationObject: attestationObject
          )
          log.info("passkey registration completed rpId=\(rpId, privacy: .public)")
          self.extensionContext.completeRegistrationRequest(using: credential)
        case .unknownAfterAccepted:
          // No rollback: this process cannot tell whether the vault changed.
          // The user is told what to check before the request is cancelled.
          log.error("passkey registration outcome unknown: the app accepted the write and did not answer")
          self.installRegistrationStop(.maybeSaved, relyingPartyId: rpId, userName: userName)
        case .appUnavailable:
          log.error("passkey registration failed: vault closed or locked before the write")
          self.cancelWithError(.failed, message: "Open Custode, unlock your vault, then try again.")
        case .alreadyExists:
          log.error("passkey registration failed: a passkey for this account appeared meanwhile")
          self.cancelWithError(.failed, message: "Custode already holds a passkey for this account.")
        case .failed:
          log.error("passkey registration failed: the app did not write the vault")
          self.cancelWithError(.failed, message: "Custode could not save the passkey.")
        }
      }
    }
  }

  private func installRegistration(_ rootView: AnyView) {
    if let registrationHost {
      registrationHost.rootView = rootView
      return
    }
    let host = NSHostingController(rootView: rootView)
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

    let host = NSHostingController(rootView: rootView)
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

  // MARK: - Error helper

  private func cancelWithError(_ code: ASExtensionError.Code, message: String? = nil) {
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
