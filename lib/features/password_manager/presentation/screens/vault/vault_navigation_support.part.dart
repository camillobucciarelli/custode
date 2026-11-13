part of '../vault_screen.dart';

/// spec-006 T7/FR-5 (screen 7): `Link AutoFill credential?` — Target /
/// Entry / Username rows, Reject / Link actions. Drives the existing
/// pending-association flow (`ConfirmAppleAutofillPendingAssociation` /
/// `RejectAppleAutofillPendingAssociation`) unchanged. A modal dialog at
/// every width (2026-09-05, user-directed: yes/no confirmations are dialogs).
class _LinkAutofillCredentialDialog extends StatelessWidget {
  const _LinkAutofillCredentialDialog({
    required this.target,
    required this.entryTitle,
    required this.username,
    required this.onReject,
    required this.onLink,
  });

  final String target;
  final String? entryTitle;
  final String? username;
  final VoidCallback onReject;
  final VoidCallback onLink;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return AlertDialog(
      title: const Text('Link AutoFill credential?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'iOS asked to associate a login you just used. The vault is '
            'updated only after you confirm.',
            style: AppTextStyles.body.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 14),
          KvFieldRow(label: 'Target', value: target, showCopyButton: false),
          const SizedBox(height: 8),
          KvFieldRow(
            label: 'Entry',
            value: entryTitle ?? 'Entry unavailable',
            showCopyButton: false,
          ),
          const SizedBox(height: 8),
          KvFieldRow(
            label: 'Username',
            value: username ?? '—',
            showCopyButton: false,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: onReject, child: const Text('Reject')),
        FilledButton(onPressed: onLink, child: const Text('Link')),
      ],
    );
  }
}

Future<void> _openAndroidAutofillSettings(BuildContext context) async {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text(
        'Android Autofill v2 is being rebuilt and is not available yet.',
      ),
    ),
  );
}

Future<void> _openBrowserAutofillSettings(BuildContext context) async {
  await Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const BrowserSetupScreen()));
}

// spec-019 FR-013: the Drive setup progress indicator belonged to the
// status card and went with it. The Sync destination's `SyncStatusHero`
// carries the same state, in the destination whose subject it is.

enum _ChildGroupAction { rename, move, delete }

Future<void> _handleChildGroupAction(
  BuildContext context, {
  required VaultGroup group,
  required _ChildGroupAction action,
  required List<VaultGroup> allGroups,
}) async {
  switch (action) {
    case _ChildGroupAction.rename:
      final name = await _showGroupDialog(
        context,
        initialName: group.name,
        title: 'Rename folder',
        actionLabel: 'Save',
      );
      if (name != null && name.name.trim().isNotEmpty && context.mounted) {
        context.read<VaultBloc>().add(
          RenameVaultGroup(groupId: group.id, newName: name.name.trim()),
        );
      }
      break;
    case _ChildGroupAction.move:
      final target = await _showMoveTargetDialog(
        context,
        allGroups,
        currentGroupId: group.id,
      );
      if (target != null && context.mounted) {
        context.read<VaultBloc>().add(
          MoveVaultGroup(groupId: group.id, targetGroupId: target.groupId),
        );
      }
      break;
    case _ChildGroupAction.delete:
      final confirmed = await _showDeleteConfirm(
        context,
        label: 'Permanently delete this empty folder?',
        actionLabel: 'Delete forever',
      );
      if (confirmed && context.mounted) {
        context.read<VaultBloc>().add(DeleteVaultGroup(group.id));
      }
      break;
  }
}
