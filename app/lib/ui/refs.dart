/// How a task or a decision is named, and the bridge back to the PC.
///
/// The app cannot write anything, so a thought had while reading has nowhere to go inside it. The
/// number is the way out: copied here, pasted into amenbo there. That is why the ref is rendered
/// whole — namespaced, the way amenbo shows it — rather than as a bare number that means nothing
/// once it leaves the screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The namespace amenbo puts on everything it shows. A bare number belongs to any tracker;
/// this is what makes it belong to one.
const _namespace = 'AMB-';

String taskRef(int id) => '${_namespace}T-$id';

String decisionRef(int id) => '${_namespace}D-$id';

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
    return Semantics(
      label: '$ref, copy',
      button: true,
      container: true,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: ref));
            if (!context.mounted) return;
            final messenger = ScaffoldMessenger.maybeOf(context);
            messenger?.showSnackBar(SnackBar(content: Text('Copied $ref')));
          },
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(ref, style: theme.textTheme.labelLarge),
                const SizedBox(width: 4),
                Icon(
                  Icons.copy_outlined,
                  size: (theme.textTheme.labelLarge?.fontSize ?? 14) * 1.1,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
