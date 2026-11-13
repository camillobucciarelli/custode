part of '../vault_screen.dart';

class _CustomFieldFormRow {
  _CustomFieldFormRow({
    required this.id,
    required this.key,
    required this.value,
    this.isProtected = false,
  });

  final int id;
  String key;
  String value;

  /// spec 023 US1b: saved as a KDBX protected string and shown like the
  /// password everywhere. The user's choice, per field.
  bool isProtected;
}

/// FR-5 (spec-004): entry editor. Text-only header (`Cancel` — title —
/// `Save`), fields gap 14, generator spark inside the password field,
/// progressive "Optional" list for custom fields / attachments / OTP.
Future<EntryEditResult?> _showEntryDialog(
  BuildContext context, {
  VaultEntry? initial,
  OtpAuthPayload? initialOtpAuth,
  String? initialTitle,
  String? initialUrl,
  bool initialPendingHint = false,
  VaultShellRouter? router,
}) async {
  return (router ?? VaultShellRouterScope.of(context)).open<EntryEditResult>(
    context: context,
    surface: EntrySurface<EntryEditResult>(
      builder: (_) => _EntryDialog(
        initial: initial,
        initialOtpAuth: initialOtpAuth,
        initialTitle: initialTitle,
        initialUrl: initialUrl,
        initialPendingHint: initialPendingHint,
      ),
    ),
  );
}

class _EntryDialog extends StatefulWidget {
  const _EntryDialog({
    this.initial,
    this.initialOtpAuth,
    this.initialTitle,
    this.initialUrl,
    this.initialPendingHint = false,
  });

  final VaultEntry? initial;
  final OtpAuthPayload? initialOtpAuth;

  /// 009 / B005 — new-entry prefills for the pending-generation confirm
  /// flow. Only used when [initial] is null.
  final String? initialTitle;
  final String? initialUrl;

  /// 009 / B005 finding M1 — when true, a caption under the password field
  /// tells the user the generated password is already filled in the browser
  /// and an empty field saves it (typing a different one would desync the
  /// vault from what the site received).
  final bool initialPendingHint;

  @override
  State<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<_EntryDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _urlController;
  final List<TextEditingController> _extraUrlControllers = [];
  late final TextEditingController _notesController;
  late final TextEditingController _otpUriController;

  /// Whether the entry's OTP string arrived protected. The OTP URI travels in
  /// its own controller and is rebuilt as a plain field on save, so this
  /// carries the file's protection attribute across that round trip
  /// (spec 023 FR-002a: never downgrade on an unrelated save).
  var _otpProtected = false;
  var _nextCustomFieldId = 0;
  late List<_CustomFieldFormRow> _customFieldRows;

  /// Keys of the record's own attachments removed in this session. Nothing is
  /// written until Save, like every other field of the form.
  final Set<String> _removedAttachmentKeys = {};
  final List<String> _attachmentPaths = [];
  final Set<String> _dirtyFields = {};
  var _showCustomFields = false;
  var _showAttachments = false;
  var _showOtp = false;
  var _isSaving = false;
  String? _titleError;
  String? _otpError;

  bool get _isDirty => _dirtyFields.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.initial?.title ?? widget.initialTitle ?? '',
    );
    _usernameController = TextEditingController(
      text: widget.initial?.username ?? widget.initialOtpAuth?.username ?? '',
    );
    _passwordController = TextEditingController(
      text: widget.initial?.password ?? '',
    );
    _urlController = TextEditingController(
      text: widget.initial?.url ?? widget.initialUrl ?? '',
    );
    _notesController = TextEditingController(text: widget.initial?.notes ?? '');
    _otpUriController = TextEditingController(
      text: widget.initial?.otpUri ?? widget.initialOtpAuth?.uri ?? '',
    );
    if (_titleController.text.isEmpty && widget.initialOtpAuth != null) {
      _titleController.text = widget.initialOtpAuth!.title;
    }

    // spec 023 FR-002a: every custom field carries a user-visible secret
    // state, and an unrelated save never downgrades one. The website and OTP
    // lists rebuild their fields from plain text on save, which would strip
    // the flag, so a protected URL-keyed string stays a custom field row —
    // where it keeps its Secret switch — rather than joining the website
    // list. The OTP field has no row of its own, so its flag is carried.
    for (final field
        in widget.initial?.customFields ?? const <VaultCustomField>[]) {
      if (isUrlFieldKey(field.key) && !field.isProtected) {
        _extraUrlControllers.add(TextEditingController(text: field.value));
      }
    }
    _otpProtected =
        widget.initial?.customFields.any(
          (field) => _isOtpFieldKey(field.key) && field.isProtected,
        ) ??
        false;
    _customFieldRows =
        widget.initial?.customFields
            .where(
              (field) =>
                  !_isOtpFieldKey(field.key) &&
                  (!isUrlFieldKey(field.key) || field.isProtected),
            )
            .map(
              (field) => _buildCustomFieldRow(
                key: field.key,
                value: field.value,
                isProtected: field.isProtected,
              ),
            )
            .toList(growable: true) ??
        <_CustomFieldFormRow>[];
    _showCustomFields = _customFieldRows.isNotEmpty;
    // A record that already holds files opens with them listed: editing shows
    // the same attachments the detail does.
    _showAttachments = widget.initial?.attachments.isNotEmpty ?? false;
    _showOtp = _otpUriController.text.isNotEmpty;
  }

  /// Captured in `didChangeDependencies` rather than read in `dispose`: by
  /// teardown the scope may already be gone, and the repo's golden convention
  /// forbids resolving a dependency during disposal for exactly that reason.
  ValueNotifier<bool>? _generatorColumnOpen;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _generatorColumnOpen = VaultShellRouterScope.of(context)
        .generatorColumnOpen;
  }

  @override
  void dispose() {
    // The flag says "the editor is showing its generator column". Only `Use`
    // used to clear it, so cancelling or saving with the column open left the
    // shell demoting `wideWithFolders` to `wide` for the rest of the session —
    // the folder column vanished until another full open-and-Use cycle. Every
    // way out of the editor is a way out of the generator column.
    _generatorColumnOpen?.value = false;
    _titleController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _urlController.dispose();
    for (final controller in _extraUrlControllers) {
      controller.dispose();
    }
    _notesController.dispose();
    _otpUriController.dispose();
    super.dispose();
  }

  void _markDirty(String field) => setState(() => _dirtyFields.add(field));

  _CustomFieldFormRow _buildCustomFieldRow({
    String key = '',
    String value = '',
    bool isProtected = false,
  }) {
    return _CustomFieldFormRow(
      id: _nextCustomFieldId++,
      key: key,
      value: value,
      isProtected: isProtected,
    );
  }

  Future<bool> _confirmDiscard() async {
    if (!_isDirty) {
      return true;
    }
    final decision = await _showDiscardDialog(context, _dirtyFields);
    return decision == true;
  }

  bool _validate() {
    final titleError = _titleController.text.trim().isEmpty
        ? 'Title is required.'
        : null;
    final otpError = _validateOtpUri(_otpUriController.text);
    final customFieldError = _validateCustomFieldRows(_customFieldRows);
    setState(() {
      _titleError = titleError;
      _otpError = otpError;
    });
    if (titleError != null || otpError != null || customFieldError != null) {
      return false;
    }
    return true;
  }

  Future<void> _handleSave() async {
    if (!_validate()) {
      return;
    }
    setState(() => _isSaving = true);
    // Argon2-backed saves are not instant (FR-5 saving overlay); the real
    // write happens in VaultBloc after this sheet returns its result, but
    // the brief overlay here communicates the same "writing" moment for
    // the create/edit round trip through the router.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    VaultOperationScope.of(context).complete(
      EntryEditResult(
        title: _titleController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        url: _urlController.text.trim(),
        notes: _notesController.text.trim(),
        otpUri: _otpUriController.text.trim(),
        customFields: _buildCustomFields(
          customFieldRows: _customFieldRows,
          otpUri: _otpUriController.text,
          extraUrls: _extraUrlControllers
              .map((controller) => controller.text)
              .toList(growable: false),
          otpProtected: _otpProtected,
        ),
        attachmentPaths: List<String>.unmodifiable(_attachmentPaths),
        removedAttachmentKeys: List<String>.unmodifiable(
          _removedAttachmentKeys,
        ),
      ),
    );
  }

  Future<void> _openGenerator(BuildContext context, bool isWide) async {
    if (isWide) {
      setState(() => _showTabletGenerator = true);
      // FR-002e: tell the shell to drop the folder column — that is what
      // makes room for this one. The records list is never what collapses.
      _generatorColumnOpen?.value = true;
      return;
    }
    final result = await _showPasswordGeneratorSheet(
      context,
      initialOptions: _optionsFromPassword(_passwordController.text),
    );
    if (result != null && mounted) {
      setState(() {
        _passwordController.text = result.password;
        _dirtyFields.add('password');
      });
    }
  }

  bool _showTabletGenerator = false;

  @override
  Widget build(BuildContext context) {
    VaultOperationScope.maybeOf(context)?.registerDiscardGuard(_confirmDiscard);
    final colors = Theme.of(context).extension<KeyVaultColors>()!;
    // spec-018 FR-002e: the generator becomes a column from the derived 995,
    // not from `Breakpoints.tablet`. The editor used its own threshold here —
    // a third component deciding layout from a fourth number, which is the
    // defect FR-002a removes. `isWide` still drives the form's own two-column
    // styling; only the generator's presentation moved to the shared rule.
    final windowWidth = MediaQuery.sizeOf(context).width;
    final isWide = windowWidth >= Breakpoints.tablet;
    final generatorFitsAsColumn =
        windowWidth >= VaultLayoutWidths.generatorColumn;
    final isEditing = widget.initial != null;

    final form = _EntryEditorForm(
      formKey: _formKey,
      isWide: isWide,
      titleController: _titleController,
      usernameController: _usernameController,
      passwordController: _passwordController,
      urlController: _urlController,
      extraUrlControllers: _extraUrlControllers,
      notesController: _notesController,
      otpUriController: _otpUriController,
      titleError: _titleError,
      otpError: _otpError,
      isEditing: isEditing,
      isSaving: _isSaving,
      showCustomFields: _showCustomFields,
      showAttachments: _showAttachments,
      showOtp: _showOtp,
      showPendingPasswordHint: widget.initialPendingHint,
      customFieldRows: _customFieldRows,
      existingAttachments: [
        for (final attachment
            in widget.initial?.attachments ?? const <VaultAttachment>[])
          if (!_removedAttachmentKeys.contains(attachment.key)) attachment,
      ],
      attachmentPaths: _attachmentPaths,
      onFieldChanged: _markDirty,
      onTitleChanged: (v) {
        _markDirty('title');
        if (_titleError != null) setState(() => _titleError = null);
      },
      onOpenGenerator: () => _openGenerator(context, generatorFitsAsColumn),
      onAddUrl: () => setState(() {
        _extraUrlControllers.add(TextEditingController());
        _markDirty('URL');
      }),
      onRemoveUrl: (index) {
        final controller = _extraUrlControllers[index];
        setState(() {
          _extraUrlControllers.removeAt(index);
          _markDirty('URL');
        });
        // The field is still in the tree this frame; dispose after it
        // unmounts.
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => controller.dispose(),
        );
      },
      onRevealCustomFields: () => setState(() => _showCustomFields = true),
      onRevealAttachments: () => setState(() => _showAttachments = true),
      onRevealOtp: () => setState(() => _showOtp = true),
      onAddCustomField: () =>
          setState(() => _customFieldRows.add(_buildCustomFieldRow())),
      onRemoveCustomField: (row) => setState(() {
        _customFieldRows.removeWhere((c) => c.id == row.id);
        _markDirty('custom fields');
      }),
      onCustomFieldChanged: () => _markDirty('custom fields'),
      onAddAttachment: () async {
        final result = await FilePicker.pickFiles(allowMultiple: false);
        final filePath = result?.files.single.path;
        if (filePath == null || filePath.isEmpty || !mounted) return;
        // Picking the same file twice would attach it twice under one name.
        if (_attachmentPaths.contains(filePath)) return;
        setState(() {
          _attachmentPaths.add(filePath);
          _markDirty('attachments');
        });
      },
      onRemoveAttachment: (path) => setState(() {
        _attachmentPaths.remove(path);
        _markDirty('attachments');
      }),
      onRemoveExistingAttachment: (attachment) => setState(() {
        _removedAttachmentKeys.add(attachment.key);
        _markDirty('attachments');
      }),
      onScanOtp: () async {
        final scanned = await _scanOtpUriFromQr(context);
        if (scanned == null || !mounted) return;
        setState(() {
          _otpUriController.text = scanned.otpUri;
          _showOtp = true;
          _markDirty('OTP URI');
          _otpError = null;
        });
      },
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _EditorHeader(
          // spec-018 FR-009a: on a wide window the editor occupies the same
          // pane as the record's detail, so a generic 'Edit item' left the
          // user with no indication of WHICH record they were editing (D7).
          // The record's own title carries that identity. 'Edit item' remains
          // the fallback for an untitled record, and 'New item' is unchanged.
          title: isEditing
              ? (widget.initial!.title.trim().isEmpty
                    ? 'Edit item'
                    : widget.initial!.title.trim())
              : 'New item',
          // Save stays tappable even with an empty title so the tap
          // surfaces the "Title is required." validation error (golden
          // #8, "Editor — constraint errors") instead of silently doing
          // nothing; it's disabled only while a save is in flight.
          canSave: !_isSaving,
          onCancel: () => VaultOperationScope.of(context).cancel(),
          onSave: _handleSave,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
            child: form,
          ),
        ),
      ],
    );

    Widget content = body;
    if (generatorFitsAsColumn && _showTabletGenerator) {
      // ponytail / disclosed gap: the mock's tablet "editor + generator"
      // frame assumes ~950px of width (rail + dimmed list + editor +
      // a 290px generator column). The vault shell's existing list+detail
      // pane split (spec-002, out of scope here) only ever gives a pane
      // ~330-450px at typical tablet widths, so a fixed 290px column would
      // overflow. Using `Flexible` with a capped max width degrades this
      // gracefully (no crash, still two visible columns) instead of
      // reproducing the mock's exact proportions — flagged as a residual
      // fidelity gap in the handoff report; the real fix is letting an
      // editor-shaped pane claim full shell width, which touches
      // _VaultNavigationLayout (spec-002 shared infra).
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(flex: 3, child: body),
          const SizedBox(
            width: 1,
            child: ColoredBox(color: Colors.transparent),
          ),
          Flexible(
            flex: 2,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 290),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceNested,
                  border: Border(left: BorderSide(color: colors.divider)),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: _GeneratorPanel(
                    title: 'Generator',
                    initialOptions: _optionsFromPassword(
                      _passwordController.text,
                    ),
                    useLabel: 'Use',
                    showRegenerateAsPill: true,
                    onUse: (password) => setState(() {
                      _passwordController.text = password;
                      _dirtyFields.add('password');
                      _showTabletGenerator = false;
                      _generatorColumnOpen?.value = false;
                    }),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Stack(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(color: colors.ground),
          child: content,
        ),
        if (_isSaving) const _SavingOverlay(),
      ],
    );
  }
}

class _EntryEditorForm extends StatelessWidget {
  const _EntryEditorForm({
    required this.formKey,
    this.isWide = false,
    required this.titleController,
    required this.usernameController,
    required this.passwordController,
    required this.urlController,
    required this.extraUrlControllers,
    required this.notesController,
    required this.otpUriController,
    required this.titleError,
    required this.otpError,
    required this.isEditing,
    required this.isSaving,
    required this.showCustomFields,
    required this.showAttachments,
    required this.showOtp,
    this.showPendingPasswordHint = false,
    required this.customFieldRows,
    required this.existingAttachments,
    required this.attachmentPaths,
    required this.onFieldChanged,
    required this.onTitleChanged,
    required this.onOpenGenerator,
    required this.onAddUrl,
    required this.onRemoveUrl,
    required this.onRevealCustomFields,
    required this.onRevealAttachments,
    required this.onRevealOtp,
    required this.onAddCustomField,
    required this.onRemoveCustomField,
    required this.onCustomFieldChanged,
    required this.onAddAttachment,
    required this.onRemoveAttachment,
    required this.onRemoveExistingAttachment,
    required this.onScanOtp,
  });

  final GlobalKey<FormState> formKey;
  final bool isWide;
  final TextEditingController titleController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final TextEditingController urlController;
  final List<TextEditingController> extraUrlControllers;
  final TextEditingController notesController;
  final TextEditingController otpUriController;
  final String? titleError;
  final String? otpError;
  final bool isEditing;
  final bool isSaving;
  final bool showCustomFields;
  final bool showAttachments;
  final bool showOtp;
  final bool showPendingPasswordHint;
  final List<_CustomFieldFormRow> customFieldRows;

  /// The record's saved attachments, minus the ones removed in this session.
  final List<VaultAttachment> existingAttachments;

  /// Files picked in this session, attached when the record is saved.
  final List<String> attachmentPaths;
  final ValueChanged<String> onFieldChanged;
  final ValueChanged<String> onTitleChanged;
  final VoidCallback onOpenGenerator;
  final VoidCallback onAddUrl;
  final ValueChanged<int> onRemoveUrl;
  final VoidCallback onRevealCustomFields;
  final VoidCallback onRevealAttachments;
  final VoidCallback onRevealOtp;
  final VoidCallback onAddCustomField;
  final ValueChanged<_CustomFieldFormRow> onRemoveCustomField;
  final VoidCallback onCustomFieldChanged;
  final VoidCallback onAddAttachment;
  final ValueChanged<String> onRemoveAttachment;
  final ValueChanged<VaultAttachment> onRemoveExistingAttachment;
  final VoidCallback onScanOtp;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<KeyVaultColors>()!;

    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          kvFieldLabel('Title', colors),
          TextFormField(
            controller: titleController,
            enabled: !isSaving,
            decoration: kvFieldDecoration(
              colors,
              hint: 'e.g. Netflix',
              errorText: titleError,
            ),
            onChanged: onTitleChanged,
          ),
          const SizedBox(height: 14),
          kvFieldLabel('Username', colors),
          TextFormField(
            controller: usernameController,
            enabled: !isSaving,
            decoration: kvFieldDecoration(colors, hint: 'Email or user name'),
            onChanged: (_) => onFieldChanged('username'),
          ),
          const SizedBox(height: 14),
          kvFieldLabel('Password', colors),
          TextFormField(
            controller: passwordController,
            enabled: !isSaving,
            style: AppTextStyles.secret.copyWith(color: colors.textPrimary),
            decoration: kvFieldDecoration(
              colors,
              hint: 'Type or generate',
              suffixIcon: SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  tooltip: 'Generate secure password',
                  onPressed: isSaving ? null : onOpenGenerator,
                  style: IconButton.styleFrom(
                    backgroundColor: colors.actionFill,
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  icon: Icon(
                    AppIcons.magic,
                    size: 17,
                    color: colors.actionText,
                    semanticLabel: 'Generate secure password',
                  ),
                ),
              ),
            ),
            onChanged: (_) => onFieldChanged('password'),
          ),
          if (showPendingPasswordHint) ...[
            const SizedBox(height: 7),
            Text(
              'Password already generated and filled in the browser — '
              'leave empty to save it',
              style: AppTextStyles.secondary.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              children: [
                Text(
                  'URL',
                  style: AppTextStyles.labelUpper.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const Spacer(),
                KvCircleIconButton(
                  glyph: AppGlyph.add,
                  tooltip: 'Add URL',
                  size: 28,
                  iconSize: 15,
                  onPressed: isSaving ? null : onAddUrl,
                ),
              ],
            ),
          ),
          TextFormField(
            controller: urlController,
            enabled: !isSaving,
            decoration: kvFieldDecoration(colors, hint: 'netflix.com'),
            onChanged: (_) => onFieldChanged('URL'),
          ),
          for (var i = 0; i < extraUrlControllers.length; i++) ...[
            const SizedBox(height: 8),
            TextFormField(
              key: ValueKey('entry-extra-url-$i'),
              controller: extraUrlControllers[i],
              enabled: !isSaving,
              decoration: kvFieldDecoration(
                colors,
                hint: 'another-site.com',
                suffixIcon: SizedBox(
                  width: 36,
                  height: 36,
                  child: IconButton(
                    tooltip: 'Remove URL',
                    onPressed: isSaving ? null : () => onRemoveUrl(i),
                    style: IconButton.styleFrom(
                      backgroundColor: colors.surfaceNested,
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    icon: KvIcon(
                      glyph: AppGlyph.close,
                      size: 15,
                      color: colors.iconNeutral,
                    ),
                  ),
                ),
              ),
              onChanged: (_) => onFieldChanged('URL'),
            ),
          ],
          const SizedBox(height: 14),
          kvFieldLabel('Notes', colors),
          TextFormField(
            controller: notesController,
            enabled: !isSaving,
            minLines: 3,
            maxLines: 5,
            decoration: kvFieldDecoration(
              colors,
              hint: 'Anything you\u2019ll need later',
            ),
            onChanged: (_) => onFieldChanged('notes'),
          ),
          const SizedBox(height: 20),
          if (!showCustomFields || !showAttachments || !showOtp) ...[
            Text(
              'Optional',
              style: AppTextStyles.labelUpper.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 9),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!showCustomFields)
                  _OptionalRow(
                    icon: AppGlyph.add,
                    label: 'Custom field',
                    onTap: () {
                      onRevealCustomFields();
                      onAddCustomField();
                    },
                  ),
                if (!showAttachments) ...[
                  if (!showCustomFields) const SizedBox(height: 8),
                  _OptionalRow(
                    icon: AppGlyph.attachment,
                    label: 'Attachment',
                    onTap: () {
                      onRevealAttachments();
                      onAddAttachment();
                    },
                  ),
                ],
                if (!showOtp) ...[
                  if (!showCustomFields || !showAttachments)
                    const SizedBox(height: 8),
                  _OptionalRow(
                    icon: AppGlyph.qrCode,
                    label: 'One-time code',
                    onTap: onRevealOtp,
                  ),
                ],
              ],
            ),
          ],
          if (showOtp) ...[
            const SizedBox(height: 20),
            kvFieldLabel('OTP URI (otpauth://\u2026)', colors),
            TextFormField(
              key: ValueKey('entry-otp-uri-${otpUriController.text}'),
              controller: otpUriController,
              enabled: !isSaving,
              minLines: 2,
              maxLines: 3,
              style: AppTextStyles.secret.copyWith(color: colors.textPrimary),
              decoration: kvFieldDecoration(
                colors,
                hint: 'otpauth://totp/...',
                errorText: otpError,
                suffixIcon: _supportsOtpQrScan()
                    ? SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton(
                          tooltip: 'Scan QR',
                          onPressed: isSaving ? null : onScanOtp,
                          style: IconButton.styleFrom(
                            backgroundColor: colors.surfaceNested,
                            shape: const CircleBorder(),
                          ),
                          icon: KvIcon(
                            glyph: AppGlyph.qrCode,
                            size: 17,
                            color: colors.iconNeutral,
                          ),
                        ),
                      )
                    : null,
              ),
              onChanged: (_) => onFieldChanged('OTP URI'),
            ),
          ],
          if (showCustomFields) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                Text(
                  'Custom fields',
                  style: AppTextStyles.labelUpper.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const Spacer(),
                KvCircleIconButton(
                  glyph: AppGlyph.add,
                  tooltip: 'Add field',
                  onPressed: isSaving ? null : onAddCustomField,
                ),
              ],
            ),
            for (final row in customFieldRows) ...[
              const SizedBox(height: 8),
              _CustomFieldRowEditor(
                key: ValueKey('entry-custom-field-row-${row.id}'),
                row: row,
                enabled: !isSaving,
                onChanged: onCustomFieldChanged,
                onRemove: () => onRemoveCustomField(row),
              ),
            ],
          ],
          if (showAttachments) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                Text(
                  'Attachments',
                  style: AppTextStyles.labelUpper.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const Spacer(),
                KvCircleIconButton(
                  glyph: AppGlyph.add,
                  tooltip: 'Add attachment',
                  onPressed: isSaving ? null : onAddAttachment,
                ),
              ],
            ),
            if (existingAttachments.isEmpty && attachmentPaths.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _kNoAttachmentsLabel,
                  style: AppTextStyles.secondary.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            // Saved files first, then the ones picked now: one list, the same
            // rows the detail shows, whether the record is new or not.
            for (final attachment in existingAttachments) ...[
              const SizedBox(height: 8),
              _AttachmentRow(
                key: ValueKey('entry-attachment-${attachment.key}'),
                name: attachment.name,
                caption: formatBytes(attachment.size),
                trailing: KvCircleIconButton(
                  glyph: AppGlyph.close,
                  tooltip: 'Remove attachment',
                  nested: true,
                  iconSize: 15,
                  onPressed: isSaving
                      ? null
                      : () => onRemoveExistingAttachment(attachment),
                ),
              ),
            ],
            for (final filePath in attachmentPaths) ...[
              const SizedBox(height: 8),
              _AttachmentRow(
                key: ValueKey('entry-new-attachment-$filePath'),
                name: path.basename(filePath),
                caption: 'Added when you save',
                trailing: KvCircleIconButton(
                  glyph: AppGlyph.close,
                  tooltip: 'Remove attachment',
                  nested: true,
                  iconSize: 15,
                  onPressed: isSaving
                      ? null
                      : () => onRemoveAttachment(filePath),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _OptionalRow extends StatelessWidget {
  const _OptionalRow({required this.icon, required this.label, this.onTap});

  final AppGlyph icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<KeyVaultColors>()!;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          // 2026-08-31: one look at every width — the wide layout's
          // surfaceNested fill melted into the pane and the rows read as
          // bare text.
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              KvIcon(glyph: icon, size: 17, color: colors.iconNeutral),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  label,
                  style: AppTextStyles.fieldValue.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              KvIcon(
                glyph: AppGlyph.chevronRight,
                size: 17,
                color: colors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomFieldRowEditor extends StatefulWidget {
  const _CustomFieldRowEditor({
    super.key,
    required this.row,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
  });

  final _CustomFieldFormRow row;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  State<_CustomFieldRowEditor> createState() => _CustomFieldRowEditorState();
}

class _CustomFieldRowEditorState extends State<_CustomFieldRowEditor> {
  /// spec 023 FR-002a: switching Secret off on a field that arrived
  /// protected is the one edit here that lowers what the file protects, so
  /// it asks first. A field made secret in this same session can be undone
  /// freely.
  late final bool _startedProtected;
  bool _valueVisible = false;

  @override
  void initState() {
    super.initState();
    _startedProtected = widget.row.isProtected;
  }

  Future<void> _setProtected(bool value) async {
    if (!value && _startedProtected) {
      final confirmed = await showKvConfirmDialog(
        context,
        title: 'Stop protecting “${widget.row.key.trim()}”?',
        body:
            'Its value will be stored in the vault as plain text, like any '
            'other custom field, and shown in clear everywhere.',
        confirmLabel: 'Store as plain text',
        cancelLabel: 'Keep secret',
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      widget.row.isProtected = value;
      _valueVisible = false;
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final enabled = widget.enabled;
    final onChanged = widget.onChanged;
    final onRemove = widget.onRemove;
    final colors = Theme.of(context).extension<KeyVaultColors>()!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      // 2026-08-31: key above value, and the same label-above-field grammar
      // as the rest of the form (_kvFieldLabel + _kvFieldDecoration) instead
      // of Material floating labels. The remove button sits beside the key
      // field so the value keeps symmetric margins.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The remove button lives in the card's header row, so Key and
          // Value stay the same full width instead of one dodging the X.
          Row(
            children: [
              Expanded(child: kvFieldLabel('Key', colors)),
              KvCircleIconButton(
                glyph: AppGlyph.close,
                tooltip: 'Remove field',
                nested: true,
                size: 30,
                iconSize: 15,
                onPressed: enabled ? onRemove : null,
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextFormField(
            initialValue: row.key,
            enabled: enabled,
            decoration: kvFieldDecoration(
              colors,
              fillColor: colors.surfaceNested,
            ),
            onChanged: (v) {
              row.key = v;
              onChanged();
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: kvFieldLabel('Value', colors)),
              if (row.isProtected)
                KvCircleIconButton(
                  glyph: _valueVisible ? AppGlyph.eyeOff : AppGlyph.eye,
                  tooltip: _valueVisible ? 'Hide value' : 'Show value',
                  nested: true,
                  size: 30,
                  iconSize: 15,
                  onPressed: enabled
                      ? () => setState(() => _valueVisible = !_valueVisible)
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 4),
          TextFormField(
            initialValue: row.value,
            enabled: enabled,
            obscureText: row.isProtected && !_valueVisible,
            decoration: kvFieldDecoration(
              colors,
              fillColor: colors.surfaceNested,
            ),
            onChanged: (v) {
              row.value = v;
              onChanged();
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Secret',
                      style: AppTextStyles.fieldValue.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      'Stored protected and shown like the password.',
                      style: AppTextStyles.meta.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              KvSwitch(
                value: row.isProtected,
                semanticLabel: 'Secret',
                onChanged: enabled ? _setProtected : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EditorHeader extends StatelessWidget {
  const _EditorHeader({
    required this.title,
    required this.canSave,
    required this.onCancel,
    required this.onSave,
  });

  final String title;
  final bool canSave;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<KeyVaultColors>()!;
    // spec-004 QA fix: the editor has no Scaffold/SafeArea of its own, so
    // the header must add the status bar/notch inset itself, same pattern
    // as _VaultDestinationScaffold in vault_shell.part.dart.
    final topInset = MediaQuery.paddingOf(context).top;
    // 2026-08-31: same header grammar as the record detail — title on the
    // left, circular icon buttons on the right (Cancel = X, Save = check).
    // The old Cancel/Save text buttons were the one header in the app not
    // built from the design's circle buttons.
    return Padding(
      // Top 26: the same visual top as the folder column, the list card and
      // the detail header; 12 below so the form does not sit glued to the
      // title row.
      padding: EdgeInsets.fromLTRB(20, 26 + topInset, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppTextStyles.headingFamily,
                fontSize: 16,
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          KvCircleIconButton(
            glyph: AppGlyph.close,
            tooltip: 'Cancel',
            onPressed: onCancel,
          ),
          const SizedBox(width: 8),
          KvCircleIconButton(
            glyph: AppGlyph.check,
            tooltip: 'Save',
            onPressed: canSave ? onSave : null,
          ),
        ],
      ),
    );
  }
}

class _SavingOverlay extends StatelessWidget {
  const _SavingOverlay();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<KeyVaultColors>()!;
    return Positioned.fill(
      child: Container(
        color: AppColors.neutral900.withValues(alpha: 0.22),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 22),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: AppColors.accent400,
                    backgroundColor: colors.divider,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Writing to the .kdbx\u2026',
                  style: AppTextStyles.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// FR-5 T17: discard-changes confirmation, naming which fields were edited
/// (proposal, per the mock — the existing unlock-screen discard guard is
/// generic; this one lists specifics). A dialog at every width.
Future<bool?> _showDiscardDialog(
  BuildContext context,
  Set<String> dirtyFields,
) {
  final fieldList = dirtyFields.toList(growable: false);
  final verb = fieldList.length == 1 ? 'was' : 'were';
  return showKvConfirmDialog(
    context,
    title: 'Discard changes?',
    body: fieldList.isEmpty
        ? 'Your unsaved record changes will be lost.'
        : '${_joinWithAnd(fieldList)} $verb edited and not saved yet.',
    confirmLabel: 'Discard',
    cancelLabel: 'Keep editing',
  );
}

String _joinWithAnd(List<String> values) {
  if (values.length == 1) return values.first;
  return '${values.sublist(0, values.length - 1).join(', ')} and ${values.last}';
}

bool _supportsOtpQrScan() {
  if (kIsWeb) {
    return false;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => false,
  };
}

Future<OtpScanResult?> _scanOtpUriFromQr(BuildContext context) async {
  if (!_supportsOtpQrScan()) {
    return null;
  }

  return VaultShellRouterScope.of(context).open<OtpScanResult>(
    context: context,
    surface: OtpScannerSurface<OtpScanResult>(
      builder: (_) => const _OtpQrScannerScreen(),
    ),
  );
}

/// FR-5 T15/T16: full-screen QR scanner for `otpauth://` codes, with a
/// dedicated camera-denied fallback showing the manual OTP URI field the
/// editor already exposes.
class _OtpQrScannerScreen extends StatefulWidget {
  const _OtpQrScannerScreen();

  @override
  State<_OtpQrScannerScreen> createState() => _OtpQrScannerScreenState();
}

class _OtpQrScannerScreenState extends State<_OtpQrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
    // Started manually below so a failure (no camera permission, or no
    // platform implementation at all — e.g. under `flutter test`, which
    // has none) is caught explicitly into `_startFailed` instead of relying
    // on `MobileScannerState.error`, which this plugin does not always
    // populate on a failed `start()`.
    autoStart: false,
  );
  bool _isHandlingCapture = false;
  bool _startFailed = false;
  final _manualUriController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.start().catchError((Object _) {
      if (mounted) setState(() => _startFailed = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _manualUriController.dispose();
    super.dispose();
  }

  void _handleDetect(BarcodeCapture capture) {
    if (_isHandlingCapture) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty) continue;

      _isHandlingCapture = true;
      if (value.startsWith('otpauth://')) {
        VaultOperationScope.of(context).complete(OtpScanResult(value));
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('QR does not contain a valid OTP URI.')),
      );
      _isHandlingCapture = false;
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: _controller,
      builder: (context, state, _) {
        if (state.error != null || _startFailed) {
          return _CameraDeniedScreen(manualUriController: _manualUriController);
        }
        return _ScanningChrome(
          controller: _controller,
          onDetect: _handleDetect,
        );
      },
    );
  }
}

class _ScanningChrome extends StatelessWidget {
  const _ScanningChrome({required this.controller, required this.onDetect});

  final MobileScannerController controller;
  final void Function(BarcodeCapture) onDetect;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.neutral900,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => VaultOperationScope.of(context).cancel(),
                    icon: const Icon(
                      AppIcons.close,
                      color: AppColors.neutral100,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      'Scan OTP QR',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: AppTextStyles.headingFamily,
                        fontSize: 16,
                        color: AppColors.neutral100,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: MobileScanner(
                      controller: controller,
                      onDetect: onDetect,
                    ),
                  ),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _ScanFrame(),
                        const SizedBox(height: 26),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 40),
                          child: Text.rich(
                            TextSpan(
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.neutral100.withValues(
                                  alpha: 0.66,
                                ),
                              ),
                              children: const [
                                TextSpan(text: 'Point the camera at the '),
                                TextSpan(
                                  text: 'otpauth://',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                                TextSpan(
                                  text:
                                      ' QR code from the site\u2019s '
                                      'two-factor setup.',
                                ),
                              ],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 34),
              child: KvSecondaryPillButton(
                label: 'Paste the URI instead',
                onPressed: () => VaultOperationScope.of(context).cancel(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    const corner = BorderSide(color: AppColors.accent400, width: 4);
    return SizedBox(
      width: 240,
      height: 240,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: _cornerBox(top: corner, left: corner, radiusTL: 26),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: _cornerBox(top: corner, right: corner, radiusTR: 26),
          ),
          Positioned(
            left: 0,
            bottom: 0,
            child: _cornerBox(bottom: corner, left: corner, radiusBL: 26),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: _cornerBox(bottom: corner, right: corner, radiusBR: 26),
          ),
        ],
      ),
    );
  }

  Widget _cornerBox({
    BorderSide top = BorderSide.none,
    BorderSide bottom = BorderSide.none,
    BorderSide left = BorderSide.none,
    BorderSide right = BorderSide.none,
    double radiusTL = 0,
    double radiusTR = 0,
    double radiusBL = 0,
    double radiusBR = 0,
  }) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        border: Border(top: top, bottom: bottom, left: left, right: right),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(radiusTL),
          topRight: Radius.circular(radiusTR),
          bottomLeft: Radius.circular(radiusBL),
          bottomRight: Radius.circular(radiusBR),
        ),
      ),
    );
  }
}

/// T16: camera permission denied — not a dead end, offers the manual
/// `OTP URI (otpauth://…)` field the editor already exposes plus a shortcut
/// to system settings.
class _CameraDeniedScreen extends StatelessWidget {
  const _CameraDeniedScreen({required this.manualUriController});

  final TextEditingController manualUriController;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<KeyVaultColors>()!;

    return ColoredBox(
      color: colors.ground,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.actionFill,
                  borderRadius: BorderRadius.circular(AppRadii.row),
                ),
                child: Icon(
                  AppIcons.videocamOff,
                  size: 30,
                  color: colors.actionText,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Camera is off for KeyVault',
                style: AppTextStyles.sheetTitleLarge.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Allow the camera in system settings to scan the QR code, or '
                'paste the setup URI by hand.',
                style: AppTextStyles.body.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: 18),
              kvFieldLabel('OTP URI (otpauth://\u2026)', colors),
              TextFormField(
                controller: manualUriController,
                minLines: 2,
                maxLines: 3,
                style: AppTextStyles.secret.copyWith(color: colors.textPrimary),
                decoration: kvFieldDecoration(
                  colors,
                  hint: 'otpauth://totp/Sella:CB77219?secret=\u2026',
                ),
              ),
              const SizedBox(height: 14),
              KvPillButton(
                label: 'Open system settings',
                // ponytail: no cross-platform "jump to app settings" plugin
                // is a project dependency yet; adding one for a single
                // button is out of scope here. Points the user there in
                // words instead of doing it programmatically.
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Enable the camera for KeyVault in your system '
                      'settings, then come back.',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 9),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: manualUriController,
                builder: (context, value, _) {
                  final trimmed = value.text.trim();
                  return KvSecondaryPillButton(
                    label: 'Save the URI',
                    onPressed: trimmed.startsWith('otpauth://')
                        ? () =>
                              VaultOperationScope.of(context)
                                  .complete(OtpScanResult(trimmed))
                        : null,
                  );
                },
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
