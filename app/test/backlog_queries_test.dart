// The reading half: which bundle a task falls into, how big a window is, where a count stops,
// and that a search is answered by the index rather than by walking the backlog.

import 'package:amenbo_viewer/store/backlog_queries.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backlog_fixture.dart';

/// Every test reads the same day, so a bundle drawn here and a count taken beside it cannot
/// disagree about which tasks are late.
final today = DateTime(2026, 8, 9);

void main() {
  late BacklogStore store;

  setUp(() => store = BacklogStore.openInMemory());
  tearDown(() => store.close());

  group('the four bundles', () {
    test('what is in progress is moving, whatever else is true of it', () {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, status: 'in_progress')),
        BacklogChange.put(
          'task',
          2,
          task(id: 2, status: 'in_progress', draft: 1),
        ),
        BacklogChange.put('task', 3, task(id: 3)),
      ]);

      final moving = store.bundle(Bundle.moving, today: today);
      expect(moving.rows.map((row) => row.id), [1, 2]);
      expect(moving.total.value, 2);
    });

    test(
      'every missing premise puts a task in stalled, and says which one',
      () {
        store.applyPage([
          BacklogChange.put('task', 1, task(id: 1)),
          BacklogChange.put('task', 2, task(id: 2, status: 'blocked')),
          BacklogChange.put('task', 3, task(id: 3, draft: 1)),
          BacklogChange.put('task', 4, task(id: 4, startOn: '2026-09-01')),
          // Waiting on 1, which is not finished.
          BacklogChange.put('task', 5, task(id: 5)),
          BacklogChange.put(
            'task_dependency',
            1,
            dependency(id: 1, taskId: 5, blockedById: 1),
          ),
          // Waiting on a decision nobody has ruled on.
          BacklogChange.put('task', 6, task(id: 6)),
          BacklogChange.put('decision', 7, decision(id: 7)),
          BacklogChange.put(
            'decision_task_link',
            1,
            decisionLink(id: 1, decisionId: 7, taskId: 6),
          ),
        ]);

        final stalled = store.bundle(Bundle.stalled, today: today);
        expect(stalled.rows.map((row) => row.id), [2, 3, 4, 5, 6]);

        final byId = {for (final row in stalled.rows) row.id: row};
        expect(
          byId[5]!.blockedBy,
          1,
          reason: 'the screen writes the blocker out by number',
        );
        expect(byId[6]!.undecided, 7);
        expect(byId[3]!.draft, isTrue);
        expect(byId[4]!.startOn, '2026-09-01');
      },
    );

    test(
      'a settled blocker and a settled decision stop holding a task back',
      () {
        store.applyPage([
          BacklogChange.put('task', 1, task(id: 1, status: 'done')),
          BacklogChange.put('task', 5, task(id: 5)),
          BacklogChange.put(
            'task_dependency',
            1,
            dependency(id: 1, taskId: 5, blockedById: 1),
          ),
          BacklogChange.put('decision', 7, decision(id: 7, status: 'accepted')),
          BacklogChange.put(
            'decision_task_link',
            1,
            decisionLink(id: 1, decisionId: 7, taskId: 5),
          ),
        ]);

        expect(store.bundle(Bundle.stalled, today: today).rows, isEmpty);
        expect(
          store.bundle(Bundle.next, today: today).rows.map((row) => row.id),
          [5],
        );
      },
    );

    test('next puts the late first, then today, then priority', () {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, priority: 'high')),
        BacklogChange.put(
          'task',
          2,
          task(id: 2, priority: 'low', dueOn: '2026-08-07'),
        ),
        BacklogChange.put(
          'task',
          3,
          task(id: 3, priority: 'low', dueOn: '2026-08-09'),
        ),
        BacklogChange.put('task', 4, task(id: 4, priority: null)),
        BacklogChange.put('task', 5, task(id: 5, priority: 'medium')),
      ]);

      expect(
        store.bundle(Bundle.next, today: today).rows.map((row) => row.id),
        [2, 3, 1, 5, 4],
      );
    });

    test('finished is the last seven days, newest first', () {
      store.applyPage([
        BacklogChange.put(
          'task',
          1,
          task(id: 1, status: 'done', completedAt: '2026-08-08T10:00:00Z'),
        ),
        BacklogChange.put(
          'task',
          2,
          task(
            id: 2,
            status: 'rejected',
            statusChangedAt: '2026-08-05T10:00:00Z',
          ),
        ),
        BacklogChange.put(
          'task',
          3,
          task(id: 3, status: 'done', completedAt: '2026-07-01T10:00:00Z'),
        ),
      ]);

      expect(
        store.bundle(Bundle.finished, today: today).rows.map((row) => row.id),
        [1, 2],
      );
    });

    test(
      'a bundle hands back a window, and says how many there are behind it',
      () {
        store.applyPage([
          for (var id = 1; id <= 25; id++)
            BacklogChange.put('task', id, task(id: id)),
        ]);

        final next = store.bundle(Bundle.next, today: today);
        expect(next.rows, hasLength(Windows.bundle));
        expect(next.total.value, 25);
        expect(next.total.overflowed, isFalse);
      },
    );
  });

  group('counting', () {
    test('a count stops at the cap instead of walking the backlog', () {
      store.applyPage([
        for (var id = 1; id <= Counted.cap + 5; id++)
          BacklogChange.put('task', id, task(id: id)),
      ]);

      final total = store.bundle(Bundle.next, today: today).total;
      expect(total.value, Counted.cap);
      expect(total.overflowed, isTrue);
    });
  });

  group('the one list face', () {
    setUp(() {
      store.applyPage([
        BacklogChange.put(
          'task',
          1,
          task(id: 1, title: 'QR に載せるものを決める', status: 'done'),
        ),
        BacklogChange.put('task', 2, task(id: 2, title: 'QR の読み取りを実装する')),
        BacklogChange.put(
          'task',
          3,
          task(id: 3, title: 'ペアリングの案内を書く', notes: 'QR を読んでペアリングする'),
        ),
        BacklogChange.put(
          'task',
          4,
          task(id: 4, title: '署名鍵を用意する', updatedAt: '2026-08-09T09:00:00Z'),
        ),
        BacklogChange.put('dimension', 1, dimension(id: 1)),
        BacklogChange.put(
          'dimension_value',
          1,
          dimensionValue(id: 1, dimensionId: 1),
        ),
        BacklogChange.put(
          'task_dimension_value',
          1,
          taskDimensionValue(id: 1, taskId: 4, dimensionId: 1, valueId: 1),
        ),
      ]);
    });

    test(
      'a search finds the word wherever it is written, closed tasks included',
      () {
        final hits = store.tasks(const TaskQuery(text: 'ペアリング'), today: today);

        expect(hits.map((row) => row.id), contains(3));
        expect(hits.single.excerpt, isNotEmpty);
      },
    );

    test('a task matching in more than one place comes back once', () {
      store.applyPage([
        BacklogChange.put(
          'task',
          5,
          task(id: 5, title: 'めずらしい語', notes: 'めずらしい語をもう一度'),
        ),
      ]);

      final hits = store.tasks(const TaskQuery(text: 'めずらしい語'), today: today);
      expect(hits.map((row) => row.id), [5]);
    });

    test('a query too short for the index is still answered', () {
      // Two characters cannot be a trigram, and `qr` is exactly the sort of thing people type.
      final hits = store.tasks(const TaskQuery(text: 'QR'), today: today);
      expect(hits.map((row) => row.id), containsAll([1, 2, 3]));
    });

    test('a category value narrows the same face', () {
      expect(
        store
            .tasks(const TaskQuery(valueId: 1), today: today)
            .map((row) => row.id),
        [4],
      );
    });

    test(
      'what changed since a moment is a fourth input, not a fourth face',
      () {
        final since = DateTime.utc(2026, 8, 9, 6);
        expect(
          store
              .tasks(TaskQuery(changedSince: since), today: today)
              .map((row) => row.id),
          [4],
        );
      },
    );

    test('a bundle and a search can be asked for together', () {
      expect(
        store
            .tasks(
              const TaskQuery(text: 'QR', bundle: Bundle.next),
              today: today,
            )
            .map((row) => row.id),
        [2, 3],
      );
    });

    test('every project on the machine arrives, and one can be picked out', () {
      store.applyPage([
        BacklogChange.put('task', 9, task(id: 9, projectId: 42)),
        BacklogChange.put('project', 16, project(id: 16)),
        BacklogChange.put('project', 42, project(id: 42, name: 'nsys')),
      ]);

      expect(
        store
            .tasks(const TaskQuery(projectId: 42), today: today)
            .map((row) => row.id),
        [9],
      );
      expect(store.projects().map((row) => row.name), [
        'amenbo-plugin-viewer',
        'nsys',
      ]);
    });
  });

  group('decisions', () {
    test(
      'an empty query lists them newest first, linked to anything or not',
      () {
        store.applyPage([
          BacklogChange.put(
            'decision',
            1,
            decision(id: 1, createdAt: '2026-08-01T00:00:00Z'),
          ),
          BacklogChange.put(
            'decision',
            2,
            decision(id: 2, createdAt: '2026-08-05T00:00:00Z'),
          ),
        ]);

        expect(store.decisions().map((row) => row.id), [2, 1]);
        expect(store.decisionCount().value, 2);
      },
    );

    test('a search reaches their bodies and their comments', () {
      store.applyPage([
        BacklogChange.put(
          'decision',
          1,
          decision(id: 1, body: 'XChaCha20 を選ぶ'),
        ),
        BacklogChange.put('decision', 2, decision(id: 2)),
        BacklogChange.put('decision_comment', 1, {
          'id': 1,
          'decision_id': 2,
          'text': 'XChaCha20 のほうが nonce が長い',
          'author_kind': 'ai',
          'created_at': '2026-08-02T00:00:00Z',
          'updated_at': '2026-08-02T00:00:00Z',
          'edited_at': null,
        }),
      ]);

      expect(store.decisions(text: 'XChaCha20').map((row) => row.id), [2, 1]);
    });
  });

  group('a task detail', () {
    test('comments open on the newest few and walk backwards', () {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1)),
        for (var id = 1; id <= 10; id++)
          BacklogChange.put(
            'task_comment',
            id,
            comment(
              id: id,
              taskId: 1,
              text: 'こめんと $id',
              createdAt: '2026-08-0${id % 9 + 1}T00:00:0${id % 10}Z',
            ),
          ),
      ]);

      final opening = store.comments(1);
      expect(opening, hasLength(Windows.comments));
      // A conversation is read forwards even when the window is taken off the end.
      expect(
        opening.first.createdAt.compareTo(opening.last.createdAt),
        lessThanOrEqualTo(0),
      );

      final older = store.comments(
        1,
        limit: Windows.commentPage,
        before: opening.first.id,
      );
      expect(older.map((row) => row.id), isNot(contains(opening.first.id)));
      expect(store.commentCount(1).value, 10);
    });

    test(
      'both directions of a dependency come back with the other side state',
      () {
        store.applyPage([
          BacklogChange.put('task', 1, task(id: 1, status: 'done')),
          BacklogChange.put('task', 2, task(id: 2)),
          BacklogChange.put(
            'task_dependency',
            1,
            dependency(id: 1, taskId: 2, blockedById: 1),
          ),
        ]);

        expect(store.blockers(2).single.status, 'done');
        expect(store.blocking(1).single.id, 2);
      },
    );

    test('chips, commits and attachments come off the same task', () {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1)),
        BacklogChange.put('dimension', 1, dimension(id: 1)),
        BacklogChange.put(
          'dimension_value',
          1,
          dimensionValue(id: 1, dimensionId: 1),
        ),
        BacklogChange.put(
          'task_dimension_value',
          1,
          taskDimensionValue(id: 1, taskId: 1, dimensionId: 1, valueId: 1),
        ),
        BacklogChange.put('task_commit', 1, taskCommit(id: 1, taskId: 1)),
        BacklogChange.put('attachment', 1, attachment(id: 1, targetId: 1)),
      ]);

      expect(store.chips(1).single.value, 'app');
      expect(store.commits(1), hasLength(1));
      // The bytes stay on the PC; the row is what says the file is there at all.
      expect(store.attachments('task', 1).single.filename, 'shot.png');
    });

    test('a decision and the tasks it governs reach each other', () {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1)),
        BacklogChange.put('decision', 7, decision(id: 7)),
        BacklogChange.put(
          'decision_task_link',
          1,
          decisionLink(id: 1, decisionId: 7, taskId: 1),
        ),
        BacklogChange.put('decision', 8, decision(id: 8)),
        BacklogChange.put('decision_edge', 1, {
          'id': 1,
          'decision_id': 8,
          'target_decision_id': 7,
          'kind': 'builds_on',
          'created_at': '2026-08-01T00:00:00Z',
          'updated_at': '2026-08-01T00:00:00Z',
          'drawn_at': '2026-08-01T00:00:00Z',
        }),
      ]);

      expect(store.decisionsFor(1).single.id, 7);
      expect(store.tasksFor(7).single.id, 1);
      expect(store.edgesFor(8).single.kind, 'builds_on');
    });
  });
}
