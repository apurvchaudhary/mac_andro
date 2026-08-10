import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mac_andro/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('overlapping meetings are grouped into one agenda column', () {
    final day = DateTime(2026, 3, 29);
    final groups = agendaGroupsForDay([
      CalendarEvent(
        title: 'First',
        location: '',
        start: DateTime(2026, 3, 29, 14, 0),
        end: DateTime(2026, 3, 29, 14, 30),
      ),
      CalendarEvent(
        title: 'Second',
        location: '',
        start: DateTime(2026, 3, 29, 14, 15),
        end: DateTime(2026, 3, 29, 14, 45),
      ),
      CalendarEvent(
        title: 'Third',
        location: '',
        start: DateTime(2026, 3, 29, 15, 0),
        end: DateTime(2026, 3, 29, 15, 30),
      ),
    ], day);

    expect(groups.length, 2);
    expect(groups.first.startMinute, 14 * 60);
    expect(groups.first.events.length, 2);
    expect(groups.first.endMinute, (14 * 60) + 45);
    expect(groups.last.startMinute, 15 * 60);
    expect(groups.last.events.length, 1);
  });

  test('free slots are calculated from work window and meetings', () {
    final slots = freeSlotsForDay(
      [
        CalendarEvent(
          title: 'Standup',
          location: '',
          start: DateTime(2026, 3, 29, 10, 0),
          end: DateTime(2026, 3, 29, 10, 30),
        ),
        CalendarEvent(
          title: 'Review',
          location: '',
          start: DateTime(2026, 3, 29, 12, 0),
          end: DateTime(2026, 3, 29, 13, 0),
        ),
      ],
      DateTime(2026, 3, 29),
      const AvailabilitySettings(
        enabled: true,
        workStartMinute: 9 * 60,
        workEndMinute: 18 * 60,
        minimumSlotMinutes: 30,
      ),
    );

    expect(slots.length, 3);
    expect(slots[0].startMinute, 9 * 60);
    expect(slots[0].endMinute, 10 * 60);
    expect(slots[1].startMinute, 10 * 60 + 30);
    expect(slots[1].endMinute, 12 * 60);
    expect(slots[2].startMinute, 13 * 60);
    expect(slots[2].endMinute, 18 * 60);
  });

  test('disabled free slot settings produce no slots', () {
    final slots = freeSlotsForDay(
      [],
      DateTime(2026, 3, 29),
      const AvailabilitySettings(
        enabled: false,
        workStartMinute: 9 * 60,
        workEndMinute: 18 * 60,
        minimumSlotMinutes: 30,
      ),
    );

    expect(slots, isEmpty);
  });

  testWidgets('dashboard renders its primary sections', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const DashboardApp());
    await tester.pumpAndSettle();

    expect(find.text('CPU'), findsOneWidget);
    expect(find.text('Meetings'), findsOneWidget);
    expect(find.text(monthYearLabel(DateTime.now())), findsOneWidget);
  });

  testWidgets('calendar month can change', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const DashboardApp());
    await tester.pumpAndSettle();

    final initialMonth = find.textContaining('202');
    expect(initialMonth, findsAtLeastNWidgets(1));

    await tester.tap(find.byIcon(Icons.chevron_right_rounded).first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('calendar tap opens full screen calendar page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const DashboardApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text(monthYearLabel(DateTime.now())));
    await tester.pumpAndSettle();

    expect(find.text(monthYearLabel(DateTime.now())), findsAtLeastNWidgets(1));
    expect(find.byType(FullScreenCalendarPage), findsOneWidget);
  });

  testWidgets('clock settings dialog opens on clock card long press', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const DashboardApp());
    await tester.pumpAndSettle();

    await tester.longPress(find.text('New Delhi'));
    await tester.pumpAndSettle();

    expect(find.text('Clock Settings'), findsOneWidget);
    expect(find.text('Number of clocks'), findsOneWidget);
    expect(find.text('Time zone'), findsAtLeastNWidgets(1));
    expect(find.text('Color'), findsAtLeastNWidgets(1));
  });

  testWidgets('data source settings page opens from a gauge long press', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const DashboardApp());
    await tester.pumpAndSettle();

    await tester.longPress(find.text('CPU'));
    await tester.pumpAndSettle();

    expect(find.text('Data Source Settings'), findsOneWidget);
    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
  });

  testWidgets('saved clock settings are restored on startup', (tester) async {
    SharedPreferences.setMockInitialValues({
      kClockConfigsPrefKey: [
        '{"zoneId":"asia_tokyo","colorId":"pink"}',
        '{"zoneId":"america_new_york","colorId":"amber"}',
        '{"zoneId":"utc","colorId":"cyan"}',
      ],
    });
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const DashboardApp());
    await tester.pumpAndSettle();

    expect(find.text('Tokyo'), findsOneWidget);
    expect(find.text('New York'), findsOneWidget);
    expect(find.text('UTC'), findsOneWidget);
  });

  testWidgets('compact landscape layout keeps all bottom sections visible', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(900, 450);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const DashboardApp());
    await tester.pumpAndSettle();

    expect(find.text('New Delhi'), findsOneWidget);
    expect(find.text(monthYearLabel(DateTime.now())), findsOneWidget);
    expect(find.text('Meetings'), findsAtLeastNWidgets(1));
  });
}
