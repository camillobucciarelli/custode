import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_checkbox.dart';
import '../../../../../core/widgets/kv_pill_button.dart';
import '../../../../../core/widgets/kv_slider.dart';
import '../../../domain/repositories/password_generator_settings_repository.dart';

/// 009 / B002 — global generator settings editor.
///
/// Draft-local edits; **Apply** validates and commits globally through the
/// repository with the loaded revision, **Cancel** publishes nothing,
/// **Reset to defaults** commits explicitly. A clean panel follows repository
/// `watch()` updates immediately; a dirty draft keeps local edits, marks the
/// external change, and a stale-revision Apply is rejected until Reload.
class PasswordGeneratorSettingsPanel extends StatefulWidget {
  const PasswordGeneratorSettingsPanel({
    super.key,
    required this.repository,
    this.onClose,
  });

  final PasswordGeneratorSettingsRepository repository;

  /// Invoked on Cancel. No repository call is made.
  final VoidCallback? onClose;

  @override
  State<PasswordGeneratorSettingsPanel> createState() =>
      _PasswordGeneratorSettingsPanelState();
}

class _PasswordGeneratorSettingsPanelState
    extends State<PasswordGeneratorSettingsPanel> {
  StreamSubscription<GeneratorSettingsSnapshot>? _subscription;

  /// Revision of the snapshot the current draft was loaded from — the
  /// `expectedRevision` sent on Apply.
  int? _loadedRevision;
  GeneratorSettingsSnapshot? _draft;
  bool _dirty = false;
  bool _externalChange = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _subscription = widget.repository.watch().listen(_onRepositoryUpdate);
    unawaited(_load());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final snapshot = await widget.repository.read();
    if (!mounted) return;
    setState(() {
      _adopt(snapshot);
    });
  }

  void _adopt(GeneratorSettingsSnapshot snapshot) {
    _draft = snapshot;
    _loadedRevision = snapshot.revision;
    _dirty = false;
    _externalChange = false;
    _errorMessage = null;
  }

  void _onRepositoryUpdate(GeneratorSettingsSnapshot snapshot) {
    if (!mounted) return;
    setState(() {
      if (!_dirty) {
        // Clean open UI follows committed updates immediately.
        _adopt(snapshot);
      } else if (snapshot.revision != _loadedRevision) {
        // Dirty draft: keep local edits, surface the external change.
        _externalChange = true;
      }
    });
  }

  void _edit(GeneratorSettingsSnapshot next) {
    setState(() {
      _draft = next;
      _dirty = true;
      _errorMessage = null;
    });
  }

  bool get _draftValid {
    final draft = _draft;
    return draft != null &&
        draft.enabledSetsCount >= 1 &&
        draft.length >= GeneratorSettingsSnapshot.minLength &&
        draft.length <= GeneratorSettingsSnapshot.maxLength;
  }

  Future<void> _apply() async {
    final draft = _draft;
    final expectedRevision = _loadedRevision;
    if (draft == null || expectedRevision == null || !_draftValid) {
      return;
    }
    try {
      final committed = await widget.repository.save(
        draft,
        expectedRevision: expectedRevision,
      );
      if (!mounted) return;
      setState(() => _adopt(committed));
    } on GeneratorSettingsStaleRevisionException {
      if (!mounted) return;
      setState(() {
        _externalChange = true;
        _errorMessage =
            'Settings changed elsewhere. Reload to review before applying.';
      });
    } on GeneratorSettingsUnsupportedVersionException {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Stored settings are from a newer version. Reset to replace them.';
      });
    } on GeneratorSettingsValidationException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Settings are invalid.';
      });
    } on GeneratorSettingsWriteException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Could not save settings. Try again.';
      });
    }
  }

  Future<void> _reset() async {
    try {
      final committed = await widget.repository.reset();
      if (!mounted) return;
      setState(() => _adopt(committed));
    } on GeneratorSettingsWriteException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Could not save settings. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final draft = _draft;
    if (draft == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Generator settings',
          style: AppTextStyles.sheetTitle.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 16),
        if (_externalChange)
          _NoticeCard(
            key: const ValueKey('generator-settings-external-change'),
            message: 'Settings changed elsewhere.',
            actionLabel: 'Reload',
            onAction: _load,
            colors: colors,
          ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _errorMessage!,
              key: const ValueKey('generator-settings-error'),
              style: AppTextStyles.body.copyWith(color: colors.attentionText),
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              'Length',
              style: AppTextStyles.labelUpper.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              '${draft.length}',
              style: TextStyle(
                fontFamily: AppTextStyles.headingFamily,
                fontSize: 18,
                color: colors.textPrimary,
              ),
            ),
          ],
        ),
        KvSlider(
          value: draft.length,
          min: GeneratorSettingsSnapshot.minLength,
          max: GeneratorSettingsSnapshot.maxLength,
          onChanged: (length) => _edit(draft.copyWith(length: length)),
        ),
        const SizedBox(height: 6),
        KvCheckboxRow(
          label: 'Lowercase letters (a-z)',
          value: draft.includeLowercase,
          onChanged: (v) => _edit(draft.copyWith(includeLowercase: v)),
        ),
        const SizedBox(height: 10),
        KvCheckboxRow(
          label: 'Uppercase letters (A-Z)',
          value: draft.includeUppercase,
          onChanged: (v) => _edit(draft.copyWith(includeUppercase: v)),
        ),
        const SizedBox(height: 10),
        KvCheckboxRow(
          label: 'Numbers (0-9)',
          value: draft.includeDigits,
          onChanged: (v) => _edit(draft.copyWith(includeDigits: v)),
        ),
        const SizedBox(height: 10),
        KvCheckboxRow(
          label: 'Special characters (!@#...)',
          value: draft.includeSymbols,
          onChanged: (v) => _edit(draft.copyWith(includeSymbols: v)),
        ),
        const SizedBox(height: 16),
        KvPillButton(
          key: const ValueKey('generator-settings-apply'),
          label: 'Apply',
          onPressed: (_dirty && _draftValid) ? _apply : null,
        ),
        const SizedBox(height: 9),
        KvSecondaryPillButton(
          key: const ValueKey('generator-settings-reset'),
          label: 'Reset to defaults',
          onPressed: _reset,
        ),
        const SizedBox(height: 9),
        KvSecondaryPillButton(
          key: const ValueKey('generator-settings-cancel'),
          label: 'Cancel',
          onPressed: widget.onClose,
        ),
      ],
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    super.key,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    required this.colors,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;
  final CustodeColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.attentionTint,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body.copyWith(color: colors.attentionText),
            ),
          ),
          TextButton(
            key: const ValueKey('generator-settings-reload'),
            onPressed: onAction,
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}
