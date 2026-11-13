part of '../vault_screen.dart';

/// spec 023 T202 — the entry detail's passkey section (FR-009, FR-011,
/// FR-012).
///
/// Everything here is metadata. The private key is never rendered, never
/// copied and never revealed, so this section has no copy button and no
/// reveal gate: a passkey is not a secret the user reads, it is a secret the
/// signer uses (Constitution I).
class _PasskeySection extends StatelessWidget {
  const _PasskeySection({required this.entry, this.onDelete});

  final VaultEntry entry;

  /// Null while a save is in flight, which disables the delete action.
  final void Function(VaultPasskey passkey)? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Column(
      key: const ValueKey('entry-detail-passkeys'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'Passkeys',
              style: AppTextStyles.labelUpper.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(width: AppSpacing.s1),
            // Constitution V: the badge carries a word, not only a glyph.
            const KvTag(label: 'Passkey', variant: KvTagVariant.neutral),
          ],
        ),
        const SizedBox(height: AppSpacing.s1),
        for (final passkey in entry.passkeys) ...[
          _PasskeyCard(
            passkey: passkey,
            onDelete: onDelete == null ? null : () => onDelete!(passkey),
          ),
          const SizedBox(height: AppSpacing.s1),
        ],
        // FR-009: the fixed note. A passkey held here has the vault's
        // security model, not the hardware key isolation a platform
        // authenticator gives — said plainly, always, not once at import.
        Text(
          _kPasskeySecurityNote,
          style: AppTextStyles.secondary.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

const _kPasskeySecurityNote =
    'A passkey stored here is protected by this vault — its master password, '
    'its key file and wherever you sync it. It is not held in hardware key '
    'isolation the way a passkey created by your device is.';

class _PasskeyCard extends StatelessWidget {
  const _PasskeyCard({required this.passkey, this.onDelete});

  final VaultPasskey passkey;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return ConstrainedBox(
      // Constitution V: a row is at least 44 dp tall.
      constraints: const BoxConstraints(minHeight: 44),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s3,
          vertical: AppSpacing.s2,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadii.row),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                KvIcon(
                  glyph: AppGlyph.fingerprint,
                  size: 17,
                  color: colors.iconNeutral,
                ),
                const SizedBox(width: AppSpacing.s1),
                Expanded(
                  child: Text(
                    passkey.relyingPartyId.isEmpty
                        ? 'Unknown site'
                        : passkey.relyingPartyId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.rowTitle.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                if (!passkey.usable) ...[
                  const SizedBox(width: AppSpacing.s1),
                  const KvTag(
                    label: 'Unusable',
                    variant: KvTagVariant.attention,
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            KvFieldRow(
              label: 'Account',
              value: passkey.username.isEmpty
                  ? 'No username'
                  : passkey.username,
              backgroundColor: colors.surfaceNested,
              showCopyButton: false,
            ),
            const SizedBox(height: AppSpacing.s1),
            KvFieldRow(
              label: 'Key type',
              value: _passkeyAlgorithmLabel(passkey.algorithm),
              backgroundColor: colors.surfaceNested,
              showCopyButton: false,
            ),
            const SizedBox(height: AppSpacing.s1),
            KvFieldRow(
              label: 'Added',
              value: _formatEntryDateTime(passkey.createdAt),
              backgroundColor: colors.surfaceNested,
              showCopyButton: false,
            ),
            const SizedBox(height: AppSpacing.s1),
            KvFieldRow(
              label: 'Backup',
              value: _passkeyBackupLabel(passkey),
              backgroundColor: colors.surfaceNested,
              showCopyButton: false,
            ),
            if (!passkey.usable) ...[
              const SizedBox(height: AppSpacing.s2),
              // FR-012: say it cannot sign in, and say why. A passkey the
              // parser could not read is still shown — dropping it would
              // hide fields that are in the file.
              Text(
                _passkeyUnusableExplanation(passkey.unusableReason!),
                style: AppTextStyles.secondary.copyWith(
                  color: colors.attentionText,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.s2),
            Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                child: TextButton(
                  onPressed: onDelete,
                  child: const Text('Delete passkey'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _passkeyAlgorithmLabel(VaultPasskeyAlgorithm algorithm) =>
    switch (algorithm) {
      VaultPasskeyAlgorithm.es256 => 'ES256 (ECDSA P-256)',
      VaultPasskeyAlgorithm.eddsa => 'EdDSA (Ed25519)',
      VaultPasskeyAlgorithm.rs256 => 'RS256 (RSA)',
      VaultPasskeyAlgorithm.unknown => 'Not recognised',
    };

/// BE without BS means the credential may be backed up but this copy is not,
/// so the two flags are one sentence rather than two raw booleans.
String _passkeyBackupLabel(VaultPasskey passkey) {
  if (!passkey.backupEligible) return 'Single device credential';
  return passkey.backupState
      ? 'Backed up across devices'
      : 'Eligible for backup, not backed up yet';
}

String _passkeyUnusableExplanation(VaultPasskeyUnusableReason reason) =>
    switch (reason) {
      VaultPasskeyUnusableReason.missingField =>
        'This passkey cannot be used to sign in: some of the fields it needs '
            'are missing from the record.',
      VaultPasskeyUnusableReason.badKey =>
        'This passkey cannot be used to sign in: its stored key cannot be '
            'read.',
      VaultPasskeyUnusableReason.unsupportedAlgorithm =>
        'This passkey cannot be used to sign in: its key uses an algorithm '
            'Custode does not support.',
      VaultPasskeyUnusableReason.unsupportedOnPlatform =>
        'This passkey cannot be used to sign in on this platform.',
    };
