import 'package:flutter/material.dart';

/// The one accent the app uses: Spotify's green, and only ever as a fill
/// behind dark text or a progress bar. Everything else is a neutral.
const Color kAccent = Color(0xFF1DB954);

/// Radii stay small and consistent: 10 for controls, 8 for small surfaces.
const double kRadius = 10;

/// One spacing scale for the whole app, so gaps are never chosen by feel.
const double kSpace4 = 4;
const double kSpace8 = 8;
const double kSpace12 = 12;
const double kSpace16 = 16;
const double kSpace24 = 24;
const double kSpace32 = 32;

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = dark ? _dark : _light;
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
  );

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: _text(base.textTheme),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: scheme.onSurface, size: 22),
      titleTextStyle: _text(base.textTheme).titleLarge?.copyWith(
        color: scheme.onSurface,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        minimumSize: const Size(40, 40),
        iconSize: 22,
      ),
    ),
    // No background colour here: it would also paint the tonal variant, which
    // is how a secondary action ended up as loud as the primary one.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        disabledBackgroundColor: scheme.surfaceContainerHigh,
        disabledForegroundColor: scheme.onSurfaceVariant,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius),
        ),
        textStyle: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outlineVariant),
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius),
        ),
        textStyle: base.textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius),
        ),
        textStyle: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      hintStyle: base.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 15, horizontal: 14),
      border: _fieldBorder(scheme.outlineVariant),
      enabledBorder: _fieldBorder(scheme.outlineVariant),
      focusedBorder: _fieldBorder(scheme.onSurfaceVariant),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: BorderSide(color: scheme.outline, width: 1.5),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.padded,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHigh,
      circularTrackColor: scheme.surfaceContainerHigh,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: base.textTheme.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      actionTextColor: scheme.inversePrimary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: scheme.outlineVariant,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titleTextStyle: base.textTheme.titleMedium?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      contentTextStyle: base.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      textStyle: base.textTheme.bodyMedium,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
    ),
  );
}

OutlineInputBorder _fieldBorder(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(kRadius),
      borderSide: BorderSide(color: color),
    );

TextTheme _text(TextTheme base) {
  return base.copyWith(
    titleLarge: base.titleLarge?.copyWith(
      fontSize: 21,
      height: 1.25,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: base.titleMedium?.copyWith(
      fontSize: 17,
      height: 1.3,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: base.titleSmall?.copyWith(
      fontSize: 15,
      height: 1.3,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: base.bodyLarge?.copyWith(fontSize: 15, height: 1.35),
    bodyMedium: base.bodyMedium?.copyWith(fontSize: 14, height: 1.4),
    bodySmall: base.bodySmall?.copyWith(fontSize: 13, height: 1.35),
    labelLarge: base.labelLarge?.copyWith(fontSize: 14, fontWeight: FontWeight.w500),
    labelMedium: base.labelMedium?.copyWith(fontSize: 12, fontWeight: FontWeight.w500),
    labelSmall: base.labelSmall?.copyWith(fontSize: 11, fontWeight: FontWeight.w500),
  );
}

const ColorScheme _light = ColorScheme(
  brightness: Brightness.light,
  primary: kAccent,
  onPrimary: Color(0xFF04130A),
  primaryContainer: Color(0xFFD9F5E3),
  onPrimaryContainer: Color(0xFF06381C),
  secondary: Color(0xFF2C332E),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFECEFEA),
  onSecondaryContainer: Color(0xFF1A1F1B),
  tertiary: Color(0xFF3F4944),
  onTertiary: Color(0xFFFFFFFF),
  error: Color(0xFFB3261E),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFBE9E7),
  onErrorContainer: Color(0xFF410E0B),
  surface: Color(0xFFFFFFFF),
  onSurface: Color(0xFF111411),
  onSurfaceVariant: Color(0xFF5C615A),
  surfaceDim: Color(0xFFE4E6E0),
  surfaceBright: Color(0xFFFFFFFF),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF7F8F4),
  surfaceContainer: Color(0xFFF2F3EF),
  surfaceContainerHigh: Color(0xFFEAEBE6),
  surfaceContainerHighest: Color(0xFFE2E4DD),
  outline: Color(0xFF787D76),
  outlineVariant: Color(0xFFD7D9D2),
  inverseSurface: Color(0xFF2C302C),
  onInverseSurface: Color(0xFFF1F2ED),
  inversePrimary: Color(0xFF7AE1A4),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);

const ColorScheme _dark = ColorScheme(
  brightness: Brightness.dark,
  primary: kAccent,
  onPrimary: Color(0xFF04130A),
  primaryContainer: Color(0xFF0B4123),
  onPrimaryContainer: Color(0xFFC8F3D8),
  secondary: Color(0xFFC3C9C1),
  onSecondary: Color(0xFF161A16),
  secondaryContainer: Color(0xFF252A24),
  onSecondaryContainer: Color(0xFFE3E7DF),
  tertiary: Color(0xFFB7C2BA),
  onTertiary: Color(0xFF0E1511),
  error: Color(0xFFFFB4AB),
  onError: Color(0xFF690005),
  errorContainer: Color(0xFF33100E),
  onErrorContainer: Color(0xFFFFDAD6),
  surface: Color(0xFF0C0E0C),
  onSurface: Color(0xFFE9ECE6),
  onSurfaceVariant: Color(0xFFA2A89F),
  surfaceDim: Color(0xFF0C0E0C),
  surfaceBright: Color(0xFF2A2E28),
  surfaceContainerLowest: Color(0xFF080A08),
  surfaceContainerLow: Color(0xFF131512),
  surfaceContainer: Color(0xFF181B17),
  surfaceContainerHigh: Color(0xFF1F221D),
  surfaceContainerHighest: Color(0xFF262A24),
  outline: Color(0xFF6F756C),
  outlineVariant: Color(0xFF2E332C),
  inverseSurface: Color(0xFFE9ECE6),
  onInverseSurface: Color(0xFF111411),
  inversePrimary: Color(0xFF0B6B36),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);
