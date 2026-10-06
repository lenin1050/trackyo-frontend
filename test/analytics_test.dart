import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackyo/trackyo_app.dart';

TransactionRecord _transaction({
  required String id,
  required TransactionType type,
  required double amount,
  required String category,
  required DateTime date,
}) =>
    TransactionRecord(
      id: id,
      type: type,
      amount: amount,
      category: category,
      description: '',
      merchant: 'Test merchant',
      paymentMethod: 'UPI',
      date: date,
      source: 'manual',
      receiptImage: '',
    );

void main() {
  group('analyticsPeriodRange', () {
    final reference = DateTime(2026, 1, 1, 18);

    test('calculates current week, month, last month across year boundary', () {
      final week = analyticsPeriodRange(
        AnalyticsPeriod.thisWeek,
        DateTime(2026, 1, 7),
      );
      expect(week.start, DateTime(2026, 1, 5));
      expect(week.end, DateTime(2026, 1, 7));

      final month = analyticsPeriodRange(
        AnalyticsPeriod.thisMonth,
        reference,
      );
      expect(month.start, DateTime(2026, 1, 1));
      expect(month.end, DateTime(2026, 1, 1));

      final lastMonth = analyticsPeriodRange(
        AnalyticsPeriod.lastMonth,
        reference,
      );
      expect(lastMonth.start, DateTime(2025, 12, 1));
      expect(lastMonth.end, DateTime(2025, 12, 31));
    });

    test('calculates year start and returns the custom range', () {
      final year = analyticsPeriodRange(
        AnalyticsPeriod.thisYear,
        reference,
      );
      expect(year.start, DateTime(2026));
      expect(year.end, DateTime(2026, 1, 1));

      final custom =
          DateTimeRange(start: DateTime(2025, 5, 3), end: DateTime(2025, 5, 9));
      expect(
        analyticsPeriodRange(
          AnalyticsPeriod.custom,
          reference,
          customRange: custom,
        ),
        custom,
      );
    });
  });

  testWidgets('analytics uses saved transactions and updates with period',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime.now();
    final previousMonth = DateTime(now.year, now.month - 1, 15);
    final transactions = [
      _transaction(
        id: 'current-income',
        type: TransactionType.income,
        amount: 400,
        category: 'Salary',
        date: now,
      ),
      _transaction(
        id: 'current-expense',
        type: TransactionType.expense,
        amount: 100,
        category: 'Food',
        date: now,
      ),
      _transaction(
        id: 'previous-income',
        type: TransactionType.income,
        amount: 800,
        category: 'Salary',
        date: previousMonth,
      ),
      _transaction(
        id: 'previous-expense',
        type: TransactionType.expense,
        amount: 200,
        category: 'Travel',
        date: previousMonth,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(home: AnalyticsView(transactions: transactions)),
    );
    await tester.pumpAndSettle();

    expect(find.text('₹400'), findsWidgets);
    expect(find.text('₹100'), findsWidgets);
    expect(find.text('₹300'), findsOneWidget);
    expect(find.text('100.0%'), findsOneWidget);
    expect(find.text('Food'), findsWidgets);

    await tester.tap(find.text('Last month'));
    await tester.pumpAndSettle();

    expect(find.text('₹800'), findsWidgets);
    expect(find.text('₹200'), findsWidgets);
    expect(find.text('₹600'), findsOneWidget);
    expect(find.text('Travel'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('analytics presents a useful empty-period state', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AnalyticsView(transactions: [])),
    );
    await tester.pumpAndSettle();

    expect(find.text('No spending data yet'), findsOneWidget);
    expect(find.text('₹0'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });
}
