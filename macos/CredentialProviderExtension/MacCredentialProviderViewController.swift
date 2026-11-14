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

  /// spec 024 T016 — the sealed queue of passkeys created here and not yet
  /// adopted into the vault by the app.
  private let pendingPasskeys = PendingPasskeyStore()

  /// spec 024 T018 — hosts the registration screens. Separate from
  /// [hostingController] because the two root views are different types and a
  /// single invocation only ever shows one of them.
  private var registrationHost: NSHostingController<PasskeyRegistrationView>?

  /// One confirmation creates one key: a second tap while the system prompt
  /// is up must not start a second ceremony.
  private var registrationInFlight = false

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
    log.info("prepareCredentialList(passkey) rpId=\(rpId, privacy: .private(mask: .hash))")
    store.wipeLegacyPlaintextArtifacts(reason: "passkey credential list")

    // spec 024 T019 / FR-10: cached passkeys plus the pending ones of the
    // published vault, under one filter.
    let allowed = Set(requestParameters.allowedCredentials.map { $0.base64URLEncodedString })
    let clientDataHash = requestParameters.clientDataHash
    let matches = PasskeyProviderLogic.offers(
      rpId: rpId,
      allowed: allowed,
      publishedDatabaseId: PasskeyProviderLogic.publishedDatabaseId(store.status()),
      cached: store.readCredentialMetadata(),
      // Envelope metadata only: nothing is unsealed before user verification.
      pending: pendingPasskeys.readMetadata()
    )
    guard !matches.isEmpty else {
      log.info("no passkey for rpId=\(rpId, privacy: .private(mask: .hash))")
      cancelWithError(.credentialIdentityNotFound)
      return
    }

    let rootView = CredentialListView(
      credentials: matches,
      searchableCredentials: matches,
      bestMatchId: matches.first?.id,
      isGlobalSearch: false,
      onSelect: { [weak self] metadata in
        let credentialId = metadata.passkeys.first {
          $0.rpId.caseInsensitiveCompare(rpId) == .orderedSame
            && (allowed.isEmpty || allowed.contains($0.credentialId))
        }?.credentialId
        self?.completePasskeyAssertion(
          recordIdentifier: metadata.id,
          rpId: rpId,
          credentialId: credentialId,
          clientDataHash: clientDataHash
        )
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

  // MARK: - Registration (spec 024 T018)

  /// The extension completes the WebAuthn ceremony itself and queues the new
  /// passkey sealed on this device; the app adopts it into the `.kdbx` at the
  /// next unlock. The extension never writes the vault.
  ///
  /// Order, with no step skippable: ES256 offered (FR-4), a published cache to
  /// bind the record to (FR-6), exclusion (FR-7), the user's confirmation,
  /// device-owner authentication, the cache still published, key and
  /// attestation, the sealed record written and read back, and only then the
  /// answer to the relying party (FR-5).
  @available(macOS 14.0, *)
  override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
    store.wipeLegacyPlaintextArtifacts(reason: "passkey registration")
    guard let request = registrationRequest as? ASPasskeyCredentialRequest,
          let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else {
      log.error("unsupported registration request → .failed")
      cancelWithError(.failed)
      return
    }
    var excludedCredentialIds: [Data] = []
    if #available(iOS 18.0, macOS 15.0, *) {
      excludedCredentialIds = request.excludedCredentials?.map { $0.credentialID } ?? []
    }
    let input = PasskeyRegistrationInput(
      // Lowercased like every cached passkey, so the rpIdHash signed at
      // registration is the one every later assertion signs.
      rpId: identity.relyingPartyIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      userName: identity.userName,
      userHandle: identity.userHandle,
      supportedAlgorithms: request.supportedAlgorithms.map { $0.rawValue },
      excludedCredentialIds: excludedCredentialIds
    )
    let clientDataHash = request.clientDataHash
    log.info("prepareInterface(forPasskeyRegistration) rpId=\(input.rpId, privacy: .private(mask: .hash))")

    guard !input.rpId.isEmpty else {
      cancelWithError(.failed)
      return
    }
    guard PasskeyProviderLogic.offersES256(input.supportedAlgorithms) else {
      log.info("registration refused: ES256 not offered rpId=\(input.rpId, privacy: .private(mask: .hash))")
      refuseRegistration(
        input,
        title: "Custode can't create this passkey",
        message: "\(input.rpId) does not accept the passkey type Custode creates (ES256). Choose another passkey provider."
      )
      return
    }
    guard let databaseId = PasskeyProviderLogic.publishedDatabaseId(store.status()) else {
      log.info("registration refused: no published cache rpId=\(input.rpId, privacy: .private(mask: .hash))")
      refuseRegistrationUntilUnlocked(input)
      return
    }

    let conflict = PasskeyProviderLogic.conflict(
      input,
      cached: store.readCredentialMetadata(),
      // Envelope metadata only: nothing is unsealed before user verification.
      pending: pendingPasskeys.readMetadata()
    )
    if conflict == .excludedCredential {
      log.info("registration refused: excluded credential held rpId=\(input.rpId, privacy: .private(mask: .hash))")
      // The code exists from iOS 18 / macOS 15, as does `excludedCredentials`,
      // so the fallback is unreachable; it is there for the compiler.
      if #available(iOS 18.0, macOS 15.0, *) {
        cancelWithError(.matchedExcludedCredential)
      } else {
        cancelWithError(.failed)
      }
      return
    }

    showRegistration(
      input,
      screen: .confirm(existingPasskey: conflict == .sameAccount),
      onConfirm: { [weak self] in
        self?.createPasskey(input, databaseId: databaseId, clientDataHash: clientDataHash)
      },
      onCancel: { [weak self] in
        log.info("registration cancelled by the user")
        self?.cancelWithError(.userCanceled)
      }
    )
  }

  /// Authenticate, re-check the vault binding, generate, queue, answer.
  /// Nothing is generated before the prompt succeeds, and the key leaves this
  /// function only inside the sealed record (SR-1, SR-3, SR-8).
  private func createPasskey(
    _ input: PasskeyRegistrationInput,
    databaseId: String,
    clientDataHash: Data
  ) {
    guard !registrationInFlight else { return }
    registrationInFlight = true
    PasskeyUserPresence.require(
      reason: "Create a passkey for \(input.rpId)"
    ) { [weak self] authenticated in
      guard let self else { return }
      guard authenticated else {
        log.info("passkey registration declined by the user")
        self.cancelWithError(.userCanceled)
        return
      }
      // The vault may have been locked, or another one published, while the
      // prompt was up. A record bound to a vault that is gone is refused.
      guard PasskeyProviderLogic.publishedDatabaseId(self.store.status()) == databaseId else {
        log.info("registration refused: cache changed during the prompt rpId=\(input.rpId, privacy: .private(mask: .hash))")
        self.refuseRegistrationUntilUnlocked(input)
        return
      }
      do {
        let registration = try PasskeyRegistrationBuilder.build(rpId: input.rpId)
        let credential = ASPasskeyRegistrationCredential(
          relyingParty: input.rpId,
          clientDataHash: clientDataHash,
          credentialID: registration.credentialID,
          attestationObject: registration.attestationObject
        )
        let record = PasskeyProviderLogic.makeRecord(
          input,
          databaseId: databaseId,
          credentialID: registration.credentialID,
          privateKeyPem: registration.privateKeyPem
        )
        let recordIdentifier = PasskeyProviderLogic.pendingRecordPrefix + record.recordId
        let quickTypeIdentity = ASPasskeyCredentialIdentity(
          relyingPartyIdentifier: record.rpId,
          userName: record.username.isEmpty ? record.rpId : record.username,
          credentialID: registration.credentialID,
          userHandle: input.userHandle.isEmpty ? Data(recordIdentifier.utf8) : input.userHandle,
          recordIdentifier: recordIdentifier
        )
        // FR-5: sealed, written and read back before the site hears "done".
        // Nothing between here and the completion call can fail.
        try self.pendingPasskeys.write(record)
        log.info("passkey registration completed rpId=\(input.rpId, privacy: .private(mask: .hash)) recordId=\(record.recordId, privacy: .public)")
        self.showRegistration(input, screen: .saved)
        self.extensionContext.completeRegistrationRequest(using: credential) { _ in
          Self.offerInQuickType(quickTypeIdentity)
        }
      } catch {
        log.error("passkey registration failed rpId=\(input.rpId, privacy: .private(mask: .hash)) error=\(String(describing: type(of: error)), privacy: .public)")
        self.cancelWithError(.failed, message: "Custode could not save the passkey. Nothing was created.")
      }
    }
  }

  /// spec 024 T019 — best effort: lets the system suggest the pending passkey
  /// without opening the list. The app's next publish replaces the whole
  /// identity set (and a lock empties it), so this entry never outlives the
  /// cache it depends on. Skipped unless the store takes incremental updates:
  /// otherwise a save may stand in for the whole set and drop every other
  /// suggestion.
  private static func offerInQuickType(_ identity: ASPasskeyCredentialIdentity) {
    let identityStore = ASCredentialIdentityStore.shared
    identityStore.getState { state in
      guard state.isEnabled, state.supportsIncrementalUpdates else { return }
      identityStore.saveCredentialIdentities([identity]) { success, _ in
        log.info("pending passkey identity saved=\(success, privacy: .public)")
      }
    }
  }

  /// FR-6: without a published cache there is no vault to bind the record to.
  private func refuseRegistrationUntilUnlocked(_ input: PasskeyRegistrationInput) {
    refuseRegistration(
      input,
      title: "Open and unlock Custode, then try again",
      message: "Custode can create a passkey only while your vault is unlocked. Nothing was created."
    )
  }

  /// `.failed` and not `.userCanceled`: the user did not decline the passkey,
  /// this provider cannot serve it, and the site must not see a success.
  private func refuseRegistration(_ input: PasskeyRegistrationInput, title: String, message: String) {
    showRegistration(
      input,
      screen: .refused(title: title, message: message),
      onCancel: { [weak self] in
        self?.cancelWithError(.failed, message: title)
      }
    )
  }

  private func showRegistration(
    _ input: PasskeyRegistrationInput,
    screen: PasskeyRegistrationView.Screen,
    onConfirm: @escaping () -> Void = {},
    onCancel: @escaping () -> Void = {}
  ) {
    let rootView = PasskeyRegistrationView(
      relyingPartyId: input.rpId,
      userName: input.userName,
      screen: screen,
      onConfirm: onConfirm,
      onCancel: onCancel
    )

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
    completePasskeyAssertion(
      recordIdentifier: recordIdentifier,
      rpId: identity.relyingPartyIdentifier,
      credentialId: identity.credentialID.base64URLEncodedString,
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
        let secret: AutofillPasskeySecret?
        if recordIdentifier.hasPrefix(PasskeyProviderLogic.pendingRecordPrefix) {
          // spec 024 T019: a passkey still waiting to be adopted signs under
          // the same rules, and only while its vault's cache is published.
          secret = PasskeyProviderLogic.pendingSecret(
            // The one record, decrypted only now that the user is verified.
            records: PasskeyProviderLogic.pendingRecordId(recordIdentifier)
              .flatMap { self.pendingPasskeys.read(recordId: $0) }.map { [$0] } ?? [],
            publishedDatabaseId: PasskeyProviderLogic.publishedDatabaseId(self.store.status()),
            recordIdentifier: recordIdentifier,
            rpId: rpId,
            credentialId: credentialId
          )
        } else {
          secret = try self.store.readCredentialSecret(id: recordIdentifier).passkeys.first { passkey in
            passkey.rpId.caseInsensitiveCompare(rpId) == .orderedSame
              && (credentialId == nil || passkey.credentialId == credentialId)
          }
        }
        guard let secret else {
          log.error("passkey not in the sealed record rpId=\(rpId, privacy: .private(mask: .hash))")
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
        log.info("passkey assertion completed rpId=\(rpId, privacy: .private(mask: .hash))")
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
