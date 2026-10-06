import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trackyo/trackyo_app.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('budget editor fields remain usable on a phone viewport',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const BudgetEditorDialog(),
                ),
                child: const Text('Open budget editor'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open budget editor'));
    await tester.pumpAndSettle();

    expect(find.text('Monthly spending limit'), findsOneWidget);
    expect(find.text('Month (YYYY-MM)'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add transaction save action is reachable on a phone viewport',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AddTransactionView(
            categories: const [
              CategoryRecord(
                id: 'food',
                name: 'Food',
                icon: 'restaurant',
                color: '#123456',
              ),
            ],
            incomeSources: const ['Salary'],
            existingSmsFingerprints: const {},
            onSaved: ({
              required type,
              required amount,
              required category,
              required incomeSource,
              required description,
              required merchant,
              required paymentMethod,
              required source,
              required date,
              receiptImage = '',
              smsFingerprint = '',
            }) async {},
            prefs: prefs,
            onCategoriesChanged: () async {},
            initialType: TransactionType.expense,
          ),
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
        ),
      ),
    );
    await tester.pumpAndSettle();
    final saveButton = find.text('Save transaction');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();

    expect(saveButton, findsOneWidget);
    expect(tester.getTopLeft(saveButton).dy, lessThan(844));
    expect(tester.getRect(saveButton).bottom, lessThanOrEqualTo(776));
    expect(tester.takeException(), isNull);
  });
}
