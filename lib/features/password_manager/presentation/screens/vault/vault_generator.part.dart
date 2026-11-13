part of '../vault_screen.dart';

/// FR-6 (spec-004): the generator, sheet gap 16. Same widget for the
/// mobile/tablet sheet, the editor's tablet third column, and the
/// standalone Vault-destination entry point (FR-6 "Standalone entry point
/// uses the same sheet").
class _GeneratorPanel extends StatefulWidget {
  const _GeneratorPanel({
    required this.initialOptions,
    this.onUse,
    this.useLabel = 'Use this password',
    this.showRegenerateAsPill = false,
    this.title = 'Generate password',
  });

  final PasswordGeneratorOptions initialOptions;
  final ValueChanged<String>? onUse;
  final String useLabel;

  /// Tablet third-column layout stacks a secondary "Regenerate" pill below
  /// the primary action instead of only the small regenerate icon inside
  /// the result box (PIXEL_SPEC "Editor con generatore aperto").
  final bool showRegenerateAsPill;
  final String title;

  @override
  State<_GeneratorPanel> createState() => _GeneratorPanelState();
}

class _GeneratorPanelState extends State<_GeneratorPanel> {
  late PasswordGeneratorOptions _options;
  String _result = '';

  @override
  void initState() {
    super.initState();
    _options = widget.initialOptions;
    _regenerate();
  }

  bool get _canGenerate =>
      _options.enabledSetsCount > 0 &&
      _options.length >= _options.enabledSetsCount;

  void _regenerate() {
    if (!_canGenerate) {
      setState(() => _result = '');
      return;
    }
    setState(() {
      _result = GetIt.instance<PasswordGeneratorService>().generate(_options);
    });
  }

  void _updateOptions(PasswordGeneratorOptions next) {
    setState(() => _options = next);
    _regenerate();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final assessment = evaluatePasswordStrength(_result);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Issue #187: the title takes whatever the short strength label
            // leaves. Two Flexibles around a Spacer split the row in thirds,
            // which ellipsised "Generator" to "Ge…" in the 1024 column.
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.sheetTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            if (_result.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(
                assessment.label,
                maxLines: 1,
                style: AppTextStyles.secondary.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colors.positiveText,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        if (!_canGenerate)
          _GeneratorErrorCard(message: _errorMessage(_options), colors: colors)
        else
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _result,
                    style: AppTextStyles.secretLarge.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 36,
                  height: 36,
                  child: IconButton(
                    tooltip: 'Regenerate',
                    onPressed: _regenerate,
                    style: IconButton.styleFrom(
                      backgroundColor: colors.surfaceNested,
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    icon: KvIcon(
                      glyph: AppGlyph.refresh,
                      size: 18,
                      color: colors.iconNeutral,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
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
              '${_options.length}',
              style: TextStyle(
                fontFamily: AppTextStyles.headingFamily,
                fontSize: 18,
                color: colors.textPrimary,
              ),
            ),
          ],
        ),
        KvSlider(
          value: _options.length,
          min: 8,
          max: 64,
          onChanged: (length) => _updateOptions(
            PasswordGeneratorOptions(
              length: length,
              includeLowercase: _options.includeLowercase,
              includeUppercase: _options.includeUppercase,
              includeDigits: _options.includeDigits,
              includeSymbols: _options.includeSymbols,
            ),
          ),
        ),
        const SizedBox(height: 6),
        KvCheckboxRow(
          label: 'Lowercase letters (a-z)',
          value: _options.includeLowercase,
          onChanged: (v) => _updateOptions(
            PasswordGeneratorOptions(
              length: _options.length,
              includeLowercase: v,
              includeUppercase: _options.includeUppercase,
              includeDigits: _options.includeDigits,
              includeSymbols: _options.includeSymbols,
            ),
          ),
        ),
        const SizedBox(height: 10),
        KvCheckboxRow(
          label: 'Uppercase letters (A-Z)',
          value: _options.includeUppercase,
          onChanged: (v) => _updateOptions(
            PasswordGeneratorOptions(
              length: _options.length,
              includeLowercase: _options.includeLowercase,
              includeUppercase: v,
              includeDigits: _options.includeDigits,
              includeSymbols: _options.includeSymbols,
            ),
          ),
        ),
        const SizedBox(height: 10),
        KvCheckboxRow(
          label: 'Numbers (0-9)',
          value: _options.includeDigits,
          onChanged: (v) => _updateOptions(
            PasswordGeneratorOptions(
              length: _options.length,
              includeLowercase: _options.includeLowercase,
              includeUppercase: _options.includeUppercase,
              includeDigits: v,
              includeSymbols: _options.includeSymbols,
            ),
          ),
        ),
        const SizedBox(height: 10),
        KvCheckboxRow(
          label: 'Special characters (!@#...)',
          value: _options.includeSymbols,
          onChanged: (v) => _updateOptions(
            PasswordGeneratorOptions(
              length: _options.length,
              includeLowercase: _options.includeLowercase,
              includeUppercase: _options.includeUppercase,
              includeDigits: _options.includeDigits,
              includeSymbols: v,
            ),
          ),
        ),
        const SizedBox(height: 16),
        KvPillButton(
          label: widget.useLabel,
          onPressed: (!_canGenerate || widget.onUse == null)
              ? null
              : () => widget.onUse!(_result),
        ),
        if (widget.showRegenerateAsPill) ...[
          const SizedBox(height: 9),
          KvSecondaryPillButton(label: 'Regenerate', onPressed: _regenerate),
        ],
      ],
    );
  }
}

class _GeneratorErrorCard extends StatelessWidget {
  const _GeneratorErrorCard({required this.message, required this.colors});

  final String message;
  final CustodeColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.attentionTint,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.errorOutline, size: 19, color: colors.attentionText),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body.copyWith(color: colors.attentionText),
            ),
          ),
        ],
      ),
    );
  }
}

// The two literal constraint-error strings are unchanged from the previous
// dialog-based generator (spec-004 non-negotiable / AC2).
String _errorMessage(PasswordGeneratorOptions options) {
  if (options.enabledSetsCount == 0) {
    return 'Select at least one character set.';
  }
  return 'Length must be at least ${options.enabledSetsCount} to include every selected set.';
}

/// Opens the generator as a bottom sheet (mobile/tablet-as-sheet contexts)
/// via [PasswordGeneratorSurface] — on tablet this already renders as a
/// pane per `VaultShellRouter.presentationFor`, not a pushed route.
/// [standalone] controls the primary action label/behaviour for the
/// Vault-destination entry point (FR-6): it copies + closes instead of
/// returning a result to an editor.
Future<GeneratedPasswordResult?> _showPasswordGeneratorSheet(
  BuildContext context, {
  PasswordGeneratorOptions initialOptions =
      const PasswordGeneratorOptions.defaults(),
  bool standalone = false,
}) {
  return VaultShellRouterScope.of(context).open<GeneratedPasswordResult>(
    context: context,
    surface: PasswordGeneratorSurface<GeneratedPasswordResult>(
      builder: (sheetContext) => _GeneratorSheetScaffold(
        initialOptions: initialOptions,
        standalone: standalone,
      ),
    ),
  );
}

class _GeneratorSheetScaffold extends StatefulWidget {
  const _GeneratorSheetScaffold({
    required this.initialOptions,
    required this.standalone,
  });

  final PasswordGeneratorOptions initialOptions;
  final bool standalone;

  @override
  State<_GeneratorSheetScaffold> createState() =>
      _GeneratorSheetScaffoldState();
}

class _GeneratorSheetScaffoldState extends State<_GeneratorSheetScaffold> {
  @override
  Widget build(BuildContext context) {
    // Sheet chrome only when actually hosted as a sheet: on wide layouts
    // this surface is a pane (`presentationFor`), where a drag handle lies
    // about the interaction and a back affordance is missing (2026-08-31).
    final isPane = _VaultPaneScope.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isPane)
            Row(
              children: [
                KvCircleIconButton(
                  glyph: AppGlyph.back,
                  tooltip: 'Back',
                  onPressed: () => VaultOperationScope.of(context).cancel(),
                ),
              ],
            ),
          const SizedBox(height: 14),
          _GeneratorPanel(
            initialOptions: widget.initialOptions,
            useLabel: widget.standalone ? 'Copy password' : 'Use this password',
            onUse: (password) async {
              if (widget.standalone) {
                await di.sl<ClipboardGuard>().copy(password);
                if (context.mounted) {
                  _showCenteredCopyToast(context, 'Copied password.');
                }
                if (context.mounted) {
                  VaultOperationScope.of(context)
                      .complete(GeneratedPasswordResult(password));
                }
                return;
              }
              VaultOperationScope.of(context)
                  .complete(GeneratedPasswordResult(password));
            },
          ),
        ],
      ),
    );
  }
}
