import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trackyo/trackyo_app.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<SharedPreferences> makePrefs() => SharedPreferences.getInstance();

  Widget profileApp(SharedPreferences prefs,
      {List<CategoryRecord>? categories, bool withBottomNavigation = false}) {
    final profile = ProfileView(
      user: const AppUser(
        id: 'user-1',
        fullName: 'Taylor Morgan',
        email: 'taylor@example.com',
      ),
      prefs: prefs,
      onLogout: () {},
      themeMode: ThemeMode.light,
      onThemeChanged: (_) {},
      onDataChanged: () async {},
      transactions: const [],
      categories: categories ??
          const [
            CategoryRecord(
              id: 'food',
              name: 'Food',
              icon: 'restaurant',
              color: '#3B82F6',
            ),
            CategoryRecord(
              id: 'other',
              name: 'Other',
              icon: 'category',
              color: '#3B82F6',
            ),
          ],
    );
    return MaterialApp(
      home: withBottomNavigation
          ? Scaffold(
              body: profile,
              bottomNavigationBar: NavigationBar(
                height: 68,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    label: 'Home',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.receipt_long_outlined),
                    label: 'Transactions',
                  ),
                ],
              ),
            )
          : profile,
    );
  }

  testWidgets('profile renders user, account and settings sections',
      (tester) async {
    final prefs = await makePrefs();
    await tester.pumpWidget(profileApp(prefs));

    expect(find.text('Taylor Morgan'), findsOneWidget);
    expect(find.text('TM'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Indian Rupee'), findsOneWidget);
    expect(find.text('Dark mode'), findsOneWidget);
    expect(find.text('Privacy & security'), findsOneWidget);
    expect(find.text('Export transactions as CSV'), findsOneWidget);
    expect(find.text('About TrackYo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edit profile updates and persists the displayed name',
      (tester) async {
    final prefs = await makePrefs();
    await tester.pumpWidget(profileApp(prefs));

    await tester.tap(find.byTooltip('Edit profile'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Jordan Lee');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Jordan Lee'), findsOneWidget);
    expect(find.text('JL'), findsOneWidget);
    expect(prefs.getString('trackyo_profile_display_name'), 'Jordan Lee');
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings toggles persist and theme toggle calls app callback',
      (tester) async {
    final prefs = await makePrefs();
    var selectedTheme = ThemeMode.system;
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileView(
          user: const AppUser(
              id: 'user-1',
              fullName: 'Taylor Morgan',
              email: 'taylor@example.com'),
          prefs: prefs,
          onLogout: () {},
          themeMode: ThemeMode.light,
          onThemeChanged: (value) => selectedTheme = value,
          onDataChanged: () async {},
          transactions: const [],
          categories: const [],
        ),
      ),
    );

    await tester.ensureVisible(find.byType(Switch).first);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Switch).at(1));
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();

    expect(selectedTheme, ThemeMode.dark);
    expect(prefs.getBool('trackyo_notifications_enabled'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear local transaction data requires confirmation',
      (tester) async {
    final prefs = await makePrefs();
    await prefs.setString('trackyo_local_transactions', 'cached-records');
    await tester.pumpWidget(profileApp(prefs));

    final action = find.text('Clear local transaction data');
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            'Transactions in your TrackYo account will not be deleted.'),
        findsOneWidget);
    expect(prefs.containsKey('trackyo_local_transactions'), isTrue);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(prefs.containsKey('trackyo_local_transactions'), isTrue);

    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear local data'));
    await tester.pumpAndSettle();
    expect(prefs.containsKey('trackyo_local_transactions'), isFalse);
    expect(find.textContaining('Account transactions are unchanged.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile scrolls without overflow on a 390 by 844 viewport',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prefs = await makePrefs();
    await tester.pumpWidget(profileApp(prefs, withBottomNavigation: true));
    final logout = find.text('Log out');
    await tester.ensureVisible(logout);
    await tester.pumpAndSettle();

    expect(logout, findsOneWidget);
    expect(tester.getRect(logout).bottom, lessThanOrEqualTo(776));
    expect(tester.takeException(), isNull);
  });
}
