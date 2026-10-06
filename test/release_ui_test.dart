import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackyo/trackyo_app.dart';

TransactionRecord _transaction(int index) => TransactionRecord(
      id: 'transaction-$index',
      type: index.isEven ? TransactionType.expense : TransactionType.income,
      amount: 120 + index.toDouble(),
      category: index.isEven ? 'Food' : 'Salary',
      incomeSource: index.isEven ? '' : 'Salary',
      description: '',
      merchant: 'Merchant $index',
      paymentMethod: 'UPI',
      date: DateTime.now().subtract(Duration(days: index)),
      source: 'manual',
      receiptImage: '',
    );

void main() {
  testWidgets('TrackYo splash branding fits on a phone viewport',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: SplashScreen()));

    expect(find.text('TrackYo'), findsOneWidget);
    expect(find.text('Track your money. Own your future.'), findsOneWidget);
    expect(find.bySemanticsLabel('TrackYo wallet logo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login and signup forms fit phone screens without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin: (_, __) async {},
          onRegister: (_, __, ___, ____) async {},
        ),
      ),
    );

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Login'), findsOneWidget);
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Confirm password'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('transaction filters and list render on phone with navigation',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransactionsView(
            transactions: List.generate(5, _transaction),
            categories: const [
              CategoryRecord(
                  id: 'food',
                  name: 'Food',
                  icon: 'restaurant',
                  color: '#16866F'),
            ],
            incomeSources: const ['Salary'],
            onDelete: (_) async {},
            onEdit: (_) async {},
            onSearchChanged: (_) {},
            onCategoryChanged: (_) {},
            onTypeChanged: (_) {},
            dateRange: null,
            onDateRangeChanged: (_) {},
            sortMode: 'newest',
            onSortChanged: (_) {},
            hasTransactions: true,
            onAddTransaction: () {},
          ),
          bottomNavigationBar: NavigationBar(
            height: 68,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
              NavigationDestination(
                  icon: Icon(Icons.receipt_long), label: 'Transactions'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Search transactions'), findsOneWidget);
    expect(find.text('Newest'), findsOneWidget);
    expect(find.text('Merchant 0'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('Merchant 4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
