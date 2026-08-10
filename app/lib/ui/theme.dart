/// One look, for both platforms, built once from the one sheet of numbers (`tokens.dart`).
///
/// Material 3 is used as-is on iOS as well as Android. The app is read in bursts of well under a
/// minute, so the thing worth spending on is that a row reads the same wherever it is met — not
/// that a switch matches the platform it is drawn on.
///
/// Three rules are kept here rather than in each screen, because a screen that forgets one of them
/// looks fine to whoever wrote it:
///
/// * **nothing states its size.** Sizes come from the text theme, which follows the setting the
///   person made in their OS. A number written into a widget stops following it.
/// * **nothing states its colour, spacing or corner either.** They come from [Palette], [Space]
///   and [Corner], so the whole app can be moved at once.
/// * **no state is carried by colour alone.** Priority, lateness and unread all come with a word
///   or a shape beside them — see `marks.dart`.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// The palette the surrounding theme is drawn from.
///
/// Most colours reach a widget through `Theme.of(context).colorScheme`; this is for the ones
/// Material has no role for — what a status, a priority or a due day is drawn in.
Palette palette(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<_PaletteOf>()?.palette ?? paletteFor(theme.brightness);
}

/// Carries [Palette] on the theme.
///
/// It does not blend from one brightness to the other: these are the colours a mark is recognised
/// by, and half of one is not a colour amenbo has. The swap happens inside the fade the rest of
/// the theme is already doing.
@immutable
class _PaletteOf extends ThemeExtension<_PaletteOf> {
  const _PaletteOf(this.palette);

  final Palette palette;

  @override
  _PaletteOf copyWith({Palette? palette}) =>
      _PaletteOf(palette ?? this.palette);

  @override
  _PaletteOf lerp(_PaletteOf? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

ThemeData viewerTheme(Brightness brightness) {
  final colours = paletteFor(brightness);
  return ThemeData(
    colorScheme: _scheme(brightness),
    textTheme: _textTheme,
    scaffoldBackgroundColor: colours.bg,
    // Read at night as much as in daylight, and often one-handed on the move, so targets stay at
    // the platform's comfortable size rather than being tightened to fit more rows in.
    visualDensity: VisualDensity.standard,
    listTileTheme: const ListTileThemeData(
      // Rows carry two or three lines; a fixed height would either clip them or leave a gap once
      // the text size goes up.
      minVerticalPadding: Space.s4,
    ),
    // Every rule in the app is this one — a hairline in the quiet border colour, with a rung of
    // the ladder either side of it.
    dividerTheme: DividerThemeData(
      color: colours.border,
      thickness: Stroke.rule,
      space: Space.s6,
    ),
    extensions: [_PaletteOf(colours)],
  );
}

/// amenbo's colours, on the Material roles that draw them.
///
/// The roles amenbo has no colour for — an error wash, the fixed pairs — keep what Material
/// derives from the accent. They are the ones nothing on these screens asks for; giving them
/// invented values would put colours on the glass that amenbo does not have.
ColorScheme _scheme(Brightness brightness) {
  final colours = paletteFor(brightness);
  final opposite = paletteFor(
    brightness == Brightness.dark ? Brightness.light : Brightness.dark,
  );
  return ColorScheme.fromSeed(
    seedColor: colours.accent,
    brightness: brightness,
  ).copyWith(
    // One accent, and no second one: secondary and tertiary are given the same colour rather than
    // a hue amenbo never shows.
    primary: colours.accent,
    onPrimary: colours.onAccent,
    primaryContainer: colours.accentWeak,
    onPrimaryContainer: colours.accentText,
    secondary: colours.accent,
    onSecondary: colours.onAccent,
    secondaryContainer: colours.accentWeak,
    onSecondaryContainer: colours.accentText,
    tertiary: colours.accent,
    onTertiary: colours.onAccent,
    tertiaryContainer: colours.accentWeak,
    onTertiaryContainer: colours.accentText,
    surfaceTint: colours.accent,

    error: colours.danger,
    onError: colours.onDanger,

    surface: colours.bg,
    onSurface: colours.text,
    onSurfaceVariant: colours.textMuted,
    surfaceContainerLowest: colours.containerLowest,
    surfaceContainerLow: colours.containerLow,
    surfaceContainer: colours.container,
    surfaceContainerHigh: colours.containerHigh,
    surfaceContainerHighest: colours.containerHigh,
    outline: colours.borderStrong,
    outlineVariant: colours.border,

    // What a snack bar is drawn on: the other brightness of the same set, so the one thing that
    // deliberately stands against the page still belongs to it.
    inverseSurface: opposite.container,
    onInverseSurface: opposite.text,
    inversePrimary: opposite.accent,
  );
}

/// The text sizes, on the Material styles that draw them.
///
/// Only the styles the app actually uses are named; the rest keep Material's own, which nothing
/// draws.
const _textTheme = TextTheme(
  headlineSmall: TextStyle(
    fontSize: Lettering.xl,
    fontWeight: Lettering.medium,
    height: Lettering.leadingTight,
  ),
  titleLarge: TextStyle(
    fontSize: Lettering.xl,
    fontWeight: Lettering.medium,
    height: Lettering.leadingTight,
  ),
  titleMedium: TextStyle(
    fontSize: Lettering.lg,
    fontWeight: Lettering.medium,
    height: Lettering.leadingTight,
  ),
  titleSmall: TextStyle(
    fontSize: Lettering.md,
    fontWeight: Lettering.medium,
    height: Lettering.leadingTight,
  ),
  bodyLarge: TextStyle(
    fontSize: Lettering.body,
    fontWeight: Lettering.normal,
    height: Lettering.leading,
  ),
  bodyMedium: TextStyle(
    fontSize: Lettering.md,
    fontWeight: Lettering.normal,
    height: Lettering.leading,
  ),
  bodySmall: TextStyle(
    fontSize: Lettering.sm,
    fontWeight: Lettering.normal,
    height: Lettering.leading,
  ),
  labelLarge: TextStyle(
    fontSize: Lettering.md,
    fontWeight: Lettering.medium,
    height: Lettering.leadingTight,
  ),
  labelMedium: TextStyle(
    fontSize: Lettering.xs,
    fontWeight: Lettering.medium,
    height: Lettering.leadingTight,
  ),
  labelSmall: TextStyle(
    fontSize: Lettering.xxs,
    fontWeight: Lettering.medium,
    height: Lettering.leadingTight,
  ),
);

/// A title as every list draws it: it wraps to a second line and stops there.
///
/// At the largest text size a phone offers, a backlog title runs well past one line. Two lines is
/// what a row can give it without the rows around it being pushed off the screen, so the title
/// takes two and the rest is cut — which is legible, where an overflowing row is not.
class RowTitle extends StatelessWidget {
  const RowTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.titleMedium,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
  );
}

/// A heading over a bundle, with how many are in it.
///
/// The count is part of the heading rather than a badge: it is read out with the heading, and it
/// is the number the person is actually after when they glance at the screen.
class BundleHeading extends StatelessWidget {
  const BundleHeading({
    super.key,
    required this.title,
    this.count,
    this.expanded,
    this.onToggle,
  });

  final String title;

  /// Already capped by the store — `999+` is what a backlog past the cap says. Null where the
  /// heading is over a handful the person just left behind and counting them says nothing.
  final String? count;

  /// Whether the rows under it are showing, for a bundle that folds. Null for one that does not,
  /// and then the heading is not a button.
  final bool? expanded;

  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall;
    final folds = expanded != null;
    final heading = Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.s6,
        Space.gutter,
        Space.s1,
      ),
      child: Row(
        children: [
          Expanded(child: Text(title, style: style)),
          if (count != null) Text(count!, style: style),
          if (folds)
            Icon(
              expanded! ? Icons.expand_less : Icons.expand_more,
              size: (style?.fontSize ?? Lettering.md) * 1.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );
    return Semantics(
      header: true,
      container: true,
      button: folds,
      label: [
        title,
        ?count,
        if (folds) expanded! ? 'showing' : 'folded',
      ].join(', '),
      child: ExcludeSemantics(
        child: folds ? InkWell(onTap: onToggle, child: heading) : heading,
      ),
    );
  }
}
