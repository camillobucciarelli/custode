import 'package:flutter/material.dart';

import '../responsive/breakpoints.dart';
import '../theme/custode_colors.dart';

/// Generic typed chooser surface: a modal bottom sheet on phones, a `Dialog`
/// (560 px max) at and above `Breakpoints.mobile`. One caller, one builder,
/// both presentations — the body never branches on width.
///
/// Extracted from the sheet styling `VaultShellRouter._defaultSheetHost`
/// already uses in spec-002 (root navigator, scroll-controlled, radius-32 top
/// corners from `AppTheme.bottomSheetTheme`). Selection/unlock screens use
/// this instead of `showDialog`: they live outside the vault shell.
///
/// Plain yes/no confirmations do not belong here: they are dialogs on every
/// width (`showKvConfirmDialog`).
class KvBottomSheet {
  KvBottomSheet._();

  /// `barrierAlpha` follows the PIXEL_SPEC bottom-sheet backdrop table:
  /// 0.42 default, 0.30 for confirmations, 0.22 for a saving overlay.
  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    double barrierAlpha = 0.42,
    bool isDismissible = true,
    bool enableDrag = true,
  }) {
    final barrierColor = Colors.black.withValues(alpha: barrierAlpha);
    if (MediaQuery.sizeOf(context).width >= Breakpoints.mobile) {
      return showDialog<T>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: isDismissible,
        barrierColor: barrierColor,
        builder: (dialogContext) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(child: builder(dialogContext)),
          ),
        ),
      );
    }
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      barrierColor: barrierColor,
      builder: (sheetContext) => KvSheetFrame(child: builder(sheetContext)),
    );
  }
}

/// The sheet chrome, drawn once for every modal bottom sheet in the app:
/// drag handle, scrolling, keyboard inset. Bodies are plain `Column`s; on a
/// short viewport their last control used to be unreachable
/// (`_DuplicateSheet` overflowed by 113 px on a Pixel).
class KvSheetFrame extends StatelessWidget {
  const KvSheetFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 46,
                height: 5,
                margin: const EdgeInsets.only(top: 12),
                decoration: BoxDecoration(
                  color: colors.divider,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}
