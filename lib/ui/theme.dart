import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 理理相簿的配色：呼應 App 圖示的漫畫風格（黃底、墨黑框線、淡藍點綴）。
abstract final class AppColors {
  static const ink = Color(0xFF15171A);
  static const yellow = Color(0xFFF6CD3C);
  static const cream = Color(0xFFFFFBEF);
  static const sky = Color(0xFFBFE3F7);
  static const blue = Color(0xFF6FB3E8);
  static const deepBlue = Color(0xFF1F6FB5);
  static const muted = Color(0xFF4A4F57);
  static const danger = Color(0xFFB3261E);
  static const disabled = Color(0xFFE7E2D0);
}

/// 漫畫風主題：粗黑框線、不模糊的實心陰影、固定淺色模式。
abstract final class AppTheme {
  static const inkSide = BorderSide(color: AppColors.ink, width: 2.5);

  static ThemeData light() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      // 主色用墨黑：文字按鈕、勾選、進度圈等預設取主色的元件才看得清楚；
      // 黃色只用在有黑框包住的填色（按鈕、分頁指示、開關）。
      primary: AppColors.ink,
      onPrimary: Colors.white,
      primaryContainer: AppColors.yellow,
      onPrimaryContainer: AppColors.ink,
      secondary: AppColors.deepBlue,
      onSecondary: Colors.white,
      secondaryContainer: AppColors.sky,
      onSecondaryContainer: AppColors.ink,
      tertiary: AppColors.deepBlue,
      onTertiary: Colors.white,
      tertiaryContainer: AppColors.sky,
      onTertiaryContainer: AppColors.ink,
      error: AppColors.danger,
      onError: Colors.white,
      errorContainer: Color(0xFFFFDAD6),
      onErrorContainer: AppColors.ink,
      surface: AppColors.cream,
      onSurface: AppColors.ink,
      onSurfaceVariant: AppColors.muted,
      outline: AppColors.ink,
      outlineVariant: Color(0xFFCFC9B6),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: Colors.white,
      surfaceContainer: Colors.white,
      surfaceContainerHigh: Colors.white,
      surfaceContainerHighest: Color(0xFFF1EBD8),
      inverseSurface: AppColors.ink,
      onInverseSurface: Colors.white,
      inversePrimary: AppColors.yellow,
    );
    const comic = ComicBorder();
    const bold = TextStyle(fontWeight: FontWeight.w800);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.cream,
      visualDensity: VisualDensity.standard,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.yellow,
        foregroundColor: AppColors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        shape: Border(bottom: BorderSide(color: AppColors.ink, width: 3)),
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        titleTextStyle: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w900,
          color: AppColors.ink,
          letterSpacing: 1,
        ),
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: ComicBorder(radius: 14, shadow: 5),
        // 不裁切：陰影畫在卡片外側。
        clipBehavior: Clip.none,
      ),
      searchBarTheme: const SearchBarThemeData(
        elevation: WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(ComicBorder(radius: 14)),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
        constraints: BoxConstraints(minHeight: 54),
        textStyle: WidgetStatePropertyAll(
          TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.ink,
          ),
        ),
        hintStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 15, color: AppColors.muted),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: inkSide,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: inkSide,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.deepBlue, width: 3),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.danger, width: 2.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.danger, width: 3),
        ),
        floatingLabelStyle: const TextStyle(
          color: AppColors.ink,
          fontWeight: FontWeight.w700,
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: inkSide,
        backgroundColor: AppColors.sky,
        selectedColor: AppColors.yellow,
        surfaceTintColor: Colors.transparent,
        labelStyle: const TextStyle(
          color: AppColors.ink,
          fontWeight: FontWeight.w700,
        ),
        iconTheme: const IconThemeData(color: AppColors.ink, size: 18),
        deleteIconColor: AppColors.ink,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        elevation: 0,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.yellow,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: inkSide,
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? AppColors.ink
                : AppColors.muted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: states.contains(WidgetState.selected)
                ? AppColors.ink
                : AppColors.muted,
          ),
        ),
      ),
      tabBarTheme: const TabBarThemeData(
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: AppColors.ink, width: 4),
        ),
        labelColor: AppColors.ink,
        unselectedLabelColor: AppColors.muted,
        labelStyle: TextStyle(fontWeight: FontWeight.w900),
        unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w700),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.yellow,
        foregroundColor: AppColors.ink,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        disabledElevation: 0,
        shape: ComicBorder(radius: 14),
        extendedTextStyle: TextStyle(fontWeight: FontWeight.w900),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.yellow,
          foregroundColor: AppColors.ink,
          disabledBackgroundColor: AppColors.disabled,
          disabledForegroundColor: AppColors.muted,
          elevation: 0,
          shape: comic,
          textStyle: const TextStyle(fontWeight: FontWeight.w900),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: AppColors.ink,
          disabledForegroundColor: AppColors.muted,
          side: inkSide,
          shape: comic,
          textStyle: const TextStyle(fontWeight: FontWeight.w900),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.ink,
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: ComicBorder(radius: 16, shadow: 6),
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w900,
          color: AppColors.ink,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: inkSide,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.ink,
        contentTextStyle: const TextStyle(color: Colors.white),
        actionTextColor: AppColors.yellow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: const ListTileThemeData(
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: AppColors.ink,
        ),
        subtitleTextStyle: TextStyle(fontSize: 13, color: AppColors.muted),
        iconColor: AppColors.ink,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.ink,
        thickness: 2,
        space: 2,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(AppColors.ink),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.yellow
              : Colors.white,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(AppColors.ink),
        trackOutlineWidth: const WidgetStatePropertyAll(2.5),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 6,
        activeTrackColor: AppColors.ink,
        inactiveTrackColor: AppColors.ink.withValues(alpha: 0.28),
        activeTickMarkColor: Colors.transparent,
        inactiveTickMarkColor: Colors.transparent,
        thumbShape: const _ComicThumb(),
        overlayColor: AppColors.yellow.withValues(alpha: 0.3),
        valueIndicatorColor: AppColors.ink,
        valueIndicatorTextStyle: const TextStyle(color: Colors.white),
        showValueIndicator: ShowValueIndicator.onDrag,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.ink,
        linearTrackColor: Colors.white,
        circularTrackColor: Colors.transparent,
      ),
      textTheme: const TextTheme(
        titleLarge: bold,
        titleMedium: bold,
        titleSmall: bold,
        labelLarge: bold,
        headlineSmall: TextStyle(fontWeight: FontWeight.w900),
        headlineMedium: TextStyle(fontWeight: FontWeight.w900),
      ),
    );
  }
}

/// 漫畫風外框：粗黑邊，右下角帶一塊不模糊的實心陰影。
///
/// 陰影畫在元件範圍之外，使用的元件不可裁切（`clipBehavior: Clip.none`），
/// 周圍也要留至少 [shadow] 的空間。
class ComicBorder extends OutlinedBorder {
  const ComicBorder({
    super.side = AppTheme.inkSide,
    this.radius = 12,
    this.shadow = 4,
    this.shadowColor = AppColors.ink,
  });

  final double radius;
  final double shadow;
  final Color shadowColor;

  RRect _rrect(Rect rect) =>
      RRect.fromRectAndRadius(rect, Radius.circular(radius));

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_rrect(rect).deflate(side.width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_rrect(rect));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final outer = _rrect(rect);
    if (shadow > 0) {
      // 只畫露在元件外面的部分，避免蓋住元件本身的底色。
      final visible = Path.combine(
        PathOperation.difference,
        Path()..addRRect(outer.shift(Offset(shadow, shadow))),
        Path()..addRRect(outer),
      );
      canvas.drawPath(visible, Paint()..color = shadowColor);
    }
    if (side.style != BorderStyle.none && side.width > 0) {
      canvas.drawRRect(outer.deflate(side.width / 2), side.toPaint());
    }
  }

  @override
  ComicBorder copyWith({
    BorderSide? side,
    double? radius,
    double? shadow,
    Color? shadowColor,
  }) => ComicBorder(
    side: side ?? this.side,
    radius: radius ?? this.radius,
    shadow: shadow ?? this.shadow,
    shadowColor: shadowColor ?? this.shadowColor,
  );

  @override
  ShapeBorder scale(double t) => ComicBorder(
    side: side.scale(t),
    radius: radius * t,
    shadow: shadow * t,
    shadowColor: shadowColor,
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) =>
      a is ComicBorder ? _lerp(a, this, t) : super.lerpFrom(a, t);

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) =>
      b is ComicBorder ? _lerp(this, b, t) : super.lerpTo(b, t);

  static ComicBorder _lerp(ComicBorder a, ComicBorder b, double t) =>
      ComicBorder(
        side: BorderSide.lerp(a.side, b.side, t),
        radius: lerpDouble(a.radius, b.radius, t)!,
        shadow: lerpDouble(a.shadow, b.shadow, t)!,
        shadowColor: Color.lerp(a.shadowColor, b.shadowColor, t)!,
      );

  @override
  bool operator ==(Object other) =>
      other is ComicBorder &&
      other.side == side &&
      other.radius == radius &&
      other.shadow == shadow &&
      other.shadowColor == shadowColor;

  @override
  int get hashCode => Object.hash(side, radius, shadow, shadowColor);
}

/// 滑桿的圓鈕：黃底黑框。
class _ComicThumb extends SliderComponentShape {
  const _ComicThumb();

  static const _radius = 11.0;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(_radius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    canvas.drawCircle(center, _radius, Paint()..color = AppColors.yellow);
    canvas.drawCircle(
      center,
      _radius - AppTheme.inkSide.width / 2,
      AppTheme.inkSide.toPaint(),
    );
  }
}

/// 頁首：黃底、底部粗黑線，內容自動避開狀態列。搜尋頁等沒有 AppBar 的頁面使用。
class ComicHeader extends StatelessWidget {
  const ComicHeader({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle.dark,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.yellow,
        border: Border(bottom: BorderSide(color: AppColors.ink, width: 3)),
      ),
      child: SafeArea(bottom: false, child: child),
    ),
  );
}

/// 進度條：黑框白底、淡藍填色。[value] 為 null 時顯示不確定進度。
class ComicProgressBar extends StatelessWidget {
  const ComicProgressBar({super.key, required this.value});
  final double? value;

  @override
  Widget build(BuildContext context) => Container(
    height: 18,
    clipBehavior: Clip.antiAlias,
    foregroundDecoration: BoxDecoration(
      border: Border.fromBorderSide(AppTheme.inkSide),
      borderRadius: BorderRadius.circular(9),
    ),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(9),
    ),
    child: LinearProgressIndicator(
      value: value,
      minHeight: 18,
      color: AppColors.blue,
      backgroundColor: Colors.white,
    ),
  );
}

/// 區塊卡片：標題 + 內容，設定頁等使用。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppColors.yellow,
                    border: Border.fromBorderSide(AppTheme.inkSide),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 20, color: AppColors.ink),
                ),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// 提示訊息列（黑框、帶圖示）。
class InfoBanner extends StatelessWidget {
  const InfoBanner(
    this.text, {
    super.key,
    this.icon = Icons.info_outline,
    this.error = false,
  });
  final String text;
  final IconData icon;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = error ? scheme.errorContainer : scheme.tertiaryContainer;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        border: Border.fromBorderSide(AppTheme.inkSide),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.ink),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
