import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throughline_wearos/main.dart';

Future<void> _ignoreLogin(String username, String password) async {}

void main() {
  test('parses timestamped Health Services heart-rate samples', () {
    final sample = HeartRateSample.fromEvent({
      'type': 'sample',
      'bpm': 72.5,
      'measuredAt': '2026-10-13T10:15:00Z',
      'accuracy': 'HIGH',
      'source': 'wear_health_services',
    });

    expect(sample.bpm, 72.5);
    expect(sample.measuredAt, DateTime.utc(2026, 10, 13, 10, 15));
    expect(sample.accuracy, 'HIGH');
    expect(sample.source, 'wear_health_services');
  });

  test('rejects malformed heart-rate samples', () {
    expect(
      () => HeartRateSample.fromEvent({'type': 'availability'}),
      throwsFormatException,
    );
  });

  testWidgets('login fields accept text and advance focus', (tester) async {
    tester.binding.platformDispatcher.views.first.physicalSize = const Size(
      454,
      454,
    );
    tester.binding.platformDispatcher.views.first.devicePixelRatio = 2;
    addTearDown(() {
      tester.binding.platformDispatcher.views.first.resetPhysicalSize();
      tester.binding.platformDispatcher.views.first.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: LoginScreen(error: null, onLogin: _ignoreLogin)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final usernameFinder = find.byKey(const Key('login-username'));
    final passwordFinder = find.byKey(const Key('login-password'));
    expect(usernameFinder, findsOneWidget);
    expect(passwordFinder, findsNothing);

    await tester.enterText(usernameFinder, 'watch-user');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(usernameFinder, findsNothing);
    expect(passwordFinder, findsOneWidget);
    expect(
      tester.widget<TextField>(passwordFinder).focusNode!.hasFocus,
      isTrue,
    );

    await tester.enterText(passwordFinder, 'watch-password');
    expect(find.text('watch-user'), findsOneWidget);
    expect(
      tester.widget<TextField>(passwordFinder).controller!.text,
      'watch-password',
    );
  });

  test('parses task fields returned by the Throughline backend', () {
    final task = BackendTask.fromJson({
      'id': 12,
      'description': 'Follow up with Alex',
      'owner': 'Me',
      'due_date': 'tomorrow',
      'reminder_at': '2026-10-12T09:00:00+00:00',
      'status': 'open',
    });

    expect(task.id, 12);
    expect(task.description, 'Follow up with Alex');
    expect(task.owner, 'Me');
    expect(task.dueDate, 'tomorrow');
    expect(task.reminderAt, isNotNull);
    expect(task.status, 'open');
  });

  test('rejects malformed backend task responses', () {
    expect(
      () => BackendTask.fromJson({'id': 'not-an-id'}),
      throwsFormatException,
    );
  });

  test('parses persistent global chat messages', () {
    final message = GlobalChatMessage.fromJson({
      'role': 'assistant',
      'content': 'You discussed the launch plan last week.',
      'created_at': '2026-10-13T10:15:00Z',
    });

    expect(message.role, 'assistant');
    expect(message.content, 'You discussed the launch plan last week.');
    expect(message.createdAt, DateTime.utc(2026, 10, 13, 10, 15).toLocal());
  });

  test('rejects malformed global chat messages', () {
    expect(
      () => GlobalChatMessage.fromJson({
        'role': 'system',
        'content': 'Not a supported role.',
        'created_at': '2026-10-13T10:15:00Z',
      }),
      throwsFormatException,
    );
  });
}
