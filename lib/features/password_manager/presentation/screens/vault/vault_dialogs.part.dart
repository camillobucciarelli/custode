part of '../vault_screen.dart';

// spec-004: the entry editor dialog (_EntryDialog/_showEntryDialog), the
// OTP QR scanner and its camera-denied fallback moved to
// vault_entry_editor.part.dart. This file keeps the other, out-of-scope
// dialogs: folder create/rename, delete confirm, move target, Drive link,
// sync conflict. Attachments have no dialog: the detail lists them and the
// editor adds and removes them.

Future<GroupEditResult?> _showGroupDialog(
  BuildContext context, {
  String? initialName,
  String title = 'Create folder',
  String actionLabel = 'Create',
}) async {
  var name = initialName ?? '';
  final formKey = GlobalKey<FormState>();
  final result = await VaultShellRouterScope.of(context).open<GroupEditResult>(
    context: context,
    surface: GroupEditSurface<GroupEditResult>(
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          insetPadding: _dialogInsetPadding(context),
          contentPadding: _dialogContentPadding(context),
          actionsOverflowDirection: VerticalDirection.down,
          actionsOverflowButtonSpacing: 8,
          content: SizedBox(
            width: _dialogContentWidth(context, 380),
            child: Form(
              key: formKey,
              child: TextFormField(
                initialValue: initialName ?? '',
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Folder name'),
                textInputAction: TextInputAction.done,
                onChanged: (value) => name = value,
                // Enter submits, same as the Create button.
                onFieldSubmitted: (_) {
                  if (!formKey.currentState!.validate()) {
                    return;
                  }
                  VaultOperationScope.of(context)
                      .complete(GroupEditResult(name.trim()));
                },
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Folder name is required.';
                  }
                  return null;
                },
              ),
            ),
          ),
          actions: _adaptiveDialogActions(context, [
            TextButton(
              onPressed: () => VaultOperationScope.of(context).cancel(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) {
                  return;
                }
                VaultOperationScope.of(context)
                    .complete(GroupEditResult(name.trim()));
              },
              child: Text(actionLabel),
            ),
          ]),
        );
      },
    ),
  );
  return result;
}

Future<bool> _showDeleteConfirm(
  BuildContext context, {
  required String label,
  String actionLabel = 'Delete',
}) async {
  final confirmed = await _showConfirmation(
    context,
    title: 'Confirm delete',
    body: label,
    confirmLabel: actionLabel,
  );
  return confirmed == ConfirmDecision.confirm;
}

Future<MoveTargetResult?> _showMoveTargetDialog(
  BuildContext context,
  List<VaultGroup> groups, {
  String? currentGroupId,
}) async {
  String selectedGroupId;
  final options = groups
      .where((group) => group.id != currentGroupId)
      .toList(growable: false);

  if (options.isEmpty) {
    return null;
  }
  selectedGroupId = options.first.id;

  return VaultShellRouterScope.of(context).open<MoveTargetResult>(
    context: context,
    surface: MoveTargetSurface<MoveTargetResult>(
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Move to folder'),
              insetPadding: _dialogInsetPadding(context),
              contentPadding: _dialogContentPadding(context),
              actionsOverflowDirection: VerticalDirection.down,
              actionsOverflowButtonSpacing: 8,
              content: DropdownButtonFormField<String>(
                initialValue: selectedGroupId,
                isExpanded: true,
                icon: const Icon(AppIcons.chevronDown),
                items: options
                    .map(
                      (group) => DropdownMenuItem(
                        value: group.id,
                        child: Text(group.name),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    selectedGroupId = value;
                  });
                },
              ),
              actions: _adaptiveDialogActions(context, [
                TextButton(
                  onPressed: () => VaultOperationScope.of(context).cancel(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () =>
                      VaultOperationScope.of(context)
                          .complete(MoveTargetResult(selectedGroupId)),
                  child: const Text('Move'),
                ),
              ]),
            );
          },
        );
      },
    ),
  );
}

// T9: sync conflict dialog/sheet moved to vault_sync.part.dart (Sync-owned).
