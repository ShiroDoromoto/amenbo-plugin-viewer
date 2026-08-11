/// How a task or a decision is named, and the bridge back to the PC.
///
/// The app cannot write anything, so a thought had while reading has nowhere to go inside it. The
/// number is the way out: copied here, pasted into Amenbo there. That is why the ref is rendered
/// whole — namespaced, the way Amenbo shows it — rather than as a bare number that means nothing
/// once it leaves the screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/words.dart';
import 'theme.dart';
import 'tokens.dart';

/// The namespace Amenbo puts on everything it shows. A bare number belongs to any tracker;
/// this is what makes it belong to one.
const _namespace = 'AMB-';

String taskRef(int id) => '${_namespace}T-$id';

String decisionRef(int id) => '${_namespace}D-$id';

/// The three lines that leave with a task or a decision: what to type on the PC, what it is, and
/// where it had got to.
///
/// Nothing longer travels. The body is on the machine the person is heading back to, and a wall of
/// notes pasted into a chat is not a message anybody reads — what has to survive the trip is the
/// number, and the two lines that let the person recognise it when it arrives.
String handoffText({
  required String ref,
  required String title,
  required String state,
}) => '$ref\n$title\n$state';

/// Out to whatever the OS offers — notes, mail, a chat.
///
/// Screens are handed this rather than calling it, so a test can watch what would have left
/// without a share sheet standing in front of it.
Future<void> shareHandoff(String text) =>
    SharePlus.instance.share(ShareParams(text: text));

/// The ref, copied when it is tapped.
///
/// Tapping is what it looks like it does, and there is nothing else a number could usefully do
/// here — the row it names is already open.
class RefChip extends StatelessWidget {
  const RefChip(this.ref, {super.key});

  final String ref;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = Words.of(context);
    return Semantics(
      label: '$ref, ${words.refCopy}',
      button: true,
      container: true,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: ref));
            if (!context.mounted) return;
            final messenger = ScaffoldMessenger.maybeOf(context);
            messenger?.showSnackBar(
              SnackBar(content: Text(words.refCopied(ref))),
            );
          },
          borderRadius: Corner.smooth,
          // The ref is drawn at the size of a label and pressed with a thumb, so what answers the
          // press is the finger's size rather than the text's.
          child: TapTarget(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.s2,
                vertical: Space.hair,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(ref, style: theme.textTheme.labelLarge),
                  const SizedBox(width: Space.s1),
                  Icon(
                    Icons.copy_outlined,
                    size:
                        (theme.textTheme.labelLarge?.fontSize ?? Lettering.md) *
                        1.1,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
