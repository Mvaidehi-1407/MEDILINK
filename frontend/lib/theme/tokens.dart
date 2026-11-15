import 'package:flutter/material.dart';

/// MediLink design tokens. Screens and components read from here; nothing hard-codes style.
/// Values start from the palette sampled in redesign/01_PHASE1_AUDIT.md §4.
abstract final class AppColors {
  // Neutrals
  static const canvas = Color(0xFFEFF5FC);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceMuted = Color(0xFFF6F9FD);
  static const border = Color(0xFFE2E9F3);
  static const borderStrong = Color(0xFFC9D4E3);
  static const ink = Color(0xFF14213D);
  static const inkSecondary = Color(0xFF55657D);
  static const inkMuted = Color(0xFF8593A8);

  // Brand
  static const primary = Color(0xFF0E7C86);
  static const primaryPressed = Color(0xFF0A646C);
  static const primaryTint = Color(0xFFDDF0F1);
  static const accent = Color(0xFF2F6FEB);
  static const accentTint = Color(0xFFDFE9FE);

  // Status
  static const danger = Color(0xFFD2222C);
  static const dangerPressed = Color(0xFFAE1820);
  static const dangerTint = Color(0xFFFFEDEF);
  static const success = Color(0xFF15803D);
  static const successTint = Color(0xFFE2F4E8);
  static const warning = Color(0xFFB45309);
  static const warningTint = Color(0xFFFFF1DC);

  // Feature tints (icon badge background, icon colour)
  static const tintBlue = (Color(0xFFDFECFF), Color(0xFF2F6FEB));
  static const tintRed = (Color(0xFFFEE1DD), Color(0xFFDC3B31));
  static const tintViolet = (Color(0xFFE8E1FF), Color(0xFF6A4FD3));
  static const tintMint = (Color(0xFFD5F3F1), Color(0xFF0E8A85));
  static const tintAmber = (Color(0xFFFFEACB), Color(0xFFD57A00));

  static const onDark = Color(0xFFFFFFFF);
}

abstract final class AppSpacing {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 48.0;

  /// Screen side gutter.
  static const gutter = 20.0;
}

abstract final class AppRadius {
  static const sm = 10.0;
  static const input = 14.0;
  static const button = 14.0;
  static const card = 18.0;
  static const sheet = 24.0;
  static const pill = 999.0;

  static const cardAll = BorderRadius.all(Radius.circular(card));
  static const buttonAll = BorderRadius.all(Radius.circular(button));
  static const inputAll = BorderRadius.all(Radius.circular(input));
}

abstract final class AppElevation {
  /// Cards sit on a 1px border plus this very soft shadow; no Material elevation.
  static const card = [BoxShadow(color: Color(0x0D14213D), blurRadius: 14, spreadRadius: -4, offset: Offset(0, 4))];
}

abstract final class AppText {
  static const family = 'PlusJakartaSans';
  static const display = 'BricolageGrotesque';

  static const _ink = AppColors.ink;

  static const displayLg = TextStyle(
    fontFamily: display,
    fontSize: 30,
    height: 1.15,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    color: _ink,
  );
  static const headline = TextStyle(
    fontFamily: family,
    fontSize: 26,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    color: _ink,
  );
  static const title = TextStyle(
    fontFamily: family,
    fontSize: 20,
    height: 1.25,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: _ink,
  );
  static const titleSm = TextStyle(
    fontFamily: family,
    fontSize: 17,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: _ink,
  );
  static const body = TextStyle(
    fontFamily: family,
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: AppColors.inkSecondary,
  );
  static const bodyStrong = TextStyle(
    fontFamily: family,
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w600,
    color: _ink,
  );
  static const bodySm = TextStyle(
    fontFamily: family,
    fontSize: 13.5,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: AppColors.inkSecondary,
  );
  static const label = TextStyle(
    fontFamily: family,
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: _ink,
  );
  static const caption = TextStyle(
    fontFamily: family,
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: AppColors.inkSecondary, // inkMuted is 3.1:1, too low for text
  );
}

/// Large numerals (vitals, countdown). Tabular so changing digits don't shift.
const appNumeral = TextStyle(
  fontFamily: AppText.family,
  fontSize: 56,
  height: 1.0,
  fontWeight: FontWeight.w700,
  letterSpacing: -1.5,
  color: AppColors.ink,
  fontFeatures: [FontFeature.tabularFigures()],
);

abstract final class AppMotion {
  static const fast = Duration(milliseconds: 150);
  static const medium = Duration(milliseconds: 250);
  // Capped at 400 ms: every transition in the app runs 150-400 ms.
  static const expressive = Duration(milliseconds: 400);

  static const standard = Curves.easeOutCubic;
  static const emphasized = Cubic(0.2, 0, 0, 1);

  /// True when the user asked the OS to remove animations.
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [d], or zero when reduce-motion is on.
  static Duration of(BuildContext context, Duration d) => reduced(context) ? Duration.zero : d;
}
