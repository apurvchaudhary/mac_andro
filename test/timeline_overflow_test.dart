import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mac_andro/main.dart';

void main() {
  for (final minutes in [5, 9, 10, 15, 20, 25, 30, 45, 60]) {
    testWidgets('$minutes-minute timeline event card does not overflow', (
      tester,
    ) async {
      final day = DateTime(2026, 8, 10);
      final event = CalendarEvent(
        title: 'Daily Sync | Eclair',
        location: '',
        start: DateTime(2026, 8, 10, 13, 30),
        end: DateTime(2026, 8, 10, 13, 30).add(Duration(minutes: minutes)),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 600,
              child: DayTimeline(events: [event], dayDate: day),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }
}
