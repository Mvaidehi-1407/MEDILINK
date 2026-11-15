import 'package:flutter/material.dart';

import 'tokens.dart';

abstract final class AppTheme {
  static ThemeData light() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.primary,
      onPrimary: AppColors.onDark,
      primaryContainer: AppColors.primaryTint,
      onPrimaryContainer: AppColors.primaryPressed,
      secondary: AppColors.accent,
      onSecondary: AppColors.onDark,
      secondaryContainer: AppColors.accentTint,
      onSecondaryContainer: AppColors.ink,
      tertiary: AppColors.accent,
      onTertiary: AppColors.onDark,
      error: AppColors.danger,
      onError: AppColors.onDark,
      errorContainer: AppColors.dangerTint,
      onErrorContainer: AppColors.dangerPressed,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
      onSurfaceVariant: AppColors.inkSecondary,
      surfaceContainerLowest: AppColors.surface,
      surfaceContainerLow: AppColors.surface,
      surfaceContainer: AppColors.surface,
      surfaceContainerHigh: AppColors.surface,
      surfaceContainerHighest: AppColors.surfaceMuted,
      surfaceTint: Colors.transparent,
      outline: AppColors.borderStrong,
      outlineVariant: AppColors.border,
      shadow: AppColors.ink,
      inverseSurface: AppColors.ink,
      onInverseSurface: AppColors.onDark,
      inversePrimary: AppColors.primaryTint,
    );

    const textTheme = TextTheme(
      displayLarge: AppText.displayLg,
      displayMedium: AppText.displayLg,
      displaySmall: AppText.displayLg,
      headlineLarge: AppText.headline,
      headlineMedium: AppText.headline,
      headlineSmall: AppText.headline,
      titleLarge: AppText.title,
      titleMedium: AppText.titleSm,
      titleSmall: AppText.bodyStrong,
      bodyLarge: AppText.body,
      bodyMedium: AppText.body,
      bodySmall: AppText.bodySm,
      labelLarge: AppText.label,
      labelMedium: AppText.caption,
      labelSmall: AppText.caption,
    );

    const buttonShape = RoundedRectangleBorder(borderRadius: AppRadius.buttonAll);
    const buttonSize = Size(64, 52);
    final buttonText = AppText.label.copyWith(fontSize: 16);

    OutlineInputBorder inputBorder(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: AppRadius.inputAll,
      borderSide: BorderSide(color: c, width: w),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: AppText.family,
      textTheme: textTheme,
      scaffoldBackgroundColor: AppColors.canvas,
      splashFactory: InkRipple.splashFactory,
      // Selected dropdown item / keyboard focus highlight: teal tint instead of M3 grey.
      focusColor: AppColors.primaryTint,
      hoverColor: AppColors.surfaceMuted,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1, space: 1),
      iconTheme: const IconThemeData(color: AppColors.inkSecondary, size: 24),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.canvas,
        surfaceTintColor: Colors.transparent,
        foregroundColor: AppColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: AppSpacing.xs,
        titleTextStyle: AppText.title,
        iconTheme: const IconThemeData(color: AppColors.ink, size: 24),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.accentTint,
        indicatorShape: const StadiumBorder(),
        elevation: 0,
        height: 72,
        shadowColor: Colors.transparent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) =>
              IconThemeData(size: 24, color: s.contains(WidgetState.selected) ? AppColors.ink : AppColors.inkSecondary),
        ),
        // 12sp, one weight for both states (no width jump); -0.3 tracking so "Connections" and
        // "Emergencies" fit a 72dp slot (5 items on a 360dp screen).
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => AppText.caption.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
            color: s.contains(WidgetState.selected) ? AppColors.ink : AppColors.inkSecondary,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onDark,
          disabledBackgroundColor: AppColors.border,
          disabledForegroundColor: AppColors.inkMuted,
          minimumSize: buttonSize,
          shape: buttonShape,
          textStyle: buttonText,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          backgroundColor: AppColors.surface,
          minimumSize: buttonSize,
          shape: buttonShape,
          side: const BorderSide(color: AppColors.borderStrong),
          textStyle: buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          minimumSize: const Size(48, 48),
          shape: buttonShape,
          textStyle: AppText.label,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: AppColors.ink),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
        labelStyle: AppText.body,
        floatingLabelStyle: WidgetStateTextStyle.resolveWith(
          (s) => AppText.bodySm.copyWith(
            fontWeight: FontWeight.w600,
            color: s.contains(WidgetState.error)
                ? AppColors.danger
                : s.contains(WidgetState.focused)
                ? AppColors.primary
                : AppColors.inkSecondary,
          ),
        ),
        hintStyle: AppText.body.copyWith(color: AppColors.inkMuted),
        helperStyle: AppText.caption.copyWith(color: AppColors.inkSecondary),
        helperMaxLines: 3,
        errorStyle: AppText.caption.copyWith(color: AppColors.danger, fontWeight: FontWeight.w600),
        errorMaxLines: 3,
        prefixIconColor: WidgetStateColor.resolveWith(
          (s) => s.contains(WidgetState.error)
              ? AppColors.danger
              : s.contains(WidgetState.focused)
              ? AppColors.primary
              : AppColors.inkMuted,
        ),
        border: inputBorder(AppColors.border),
        enabledBorder: inputBorder(AppColors.border),
        focusedBorder: inputBorder(AppColors.primary, 2),
        errorBorder: inputBorder(AppColors.danger),
        focusedErrorBorder: inputBorder(AppColors.danger, 2),
        disabledBorder: inputBorder(AppColors.border),
      ),
      cardTheme: const CardThemeData(
        margin: EdgeInsets.zero,
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.cardAll,
          side: BorderSide(color: AppColors.border),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: AppColors.inkSecondary,
        textColor: AppColors.ink,
        titleTextStyle: AppText.bodyStrong,
        subtitleTextStyle: AppText.bodySm,
        minVerticalPadding: AppSpacing.sm,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.cardAll),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surfaceMuted,
        selectedColor: AppColors.primaryTint,
        side: const BorderSide(color: AppColors.border),
        shape: const StadiumBorder(),
        labelStyle: AppText.bodySm.copyWith(color: AppColors.ink, fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.xxs),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.sheet))),
        titleTextStyle: AppText.title,
        contentTextStyle: AppText.body,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: AppColors.surface,
        elevation: 0,
        showDragHandle: true,
        dragHandleColor: AppColors.borderStrong,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet))),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.ink,
        contentTextStyle: AppText.body.copyWith(color: AppColors.onDark),
        actionTextColor: AppColors.primaryTint,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.buttonAll),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.onDark : AppColors.inkMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.surfaceMuted,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.borderStrong,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primary,
        linearTrackColor: AppColors.primaryTint,
        circularTrackColor: Colors.transparent,
        linearMinHeight: 6,
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shadowColor: const Color(0x3314213D),
        textStyle: AppText.bodyStrong,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.input)),
          side: BorderSide(color: AppColors.border),
        ),
      ),
    );
  }
}
