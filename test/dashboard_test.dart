import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackyo/trackyo_app.dart';

TransactionRecord _transaction({
  required String id,
  required TransactionType type,
  required double amount,
  required DateTime date,
  String category = 'Food',
  String merchant = '',
}) =>
    TransactionRecord(
      id: id,
      type: type,
      amount: amount,
      category: category,
      description: 'Transaction $id',
      merchant: merchant,
      paymentMethod: 'UPI',
      date: date,
      source: 'manual',
      receiptImage: '',
    );

BudgetRecord _budget(double amount, String month) => BudgetRecord(
      id: 'budget',
      category: overallBudgetCategory,
      amount: amount,
      month: month,
    );

Widget _dashboardApp({
  required List<TransactionRecord> transactions,
  required AnalyticsSummary summary,
  List<BudgetRecord> budgets = const [],
  List<String> insights = const [],
  VoidCallback? onViewAll,
  VoidCallback? onScanReceipt,
  VoidCallback? onScanSms,
}) {
  return MaterialApp(
    home: Scaffold(
      body: DashboardView(
        user: const AppUser(
          id: 'test-user',
          fullName: 'Lenin Example',
          email: 'lenin@example.com',
        ),
        transactions: transactions,
        summary: summary,
        insights: insights,
        budgets: budgets,
        monthlyData: const [],
        onRefresh: () async {},
        onAddTransaction: (_) {},
        onScanReceipt: onScanReceipt ?? () {},
        onScanSms: onScanSms ?? () {},
        onOpenTransactions: onViewAll ?? () {},
        onOpenAi: () {},
        onManageBudget: () {},
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
  );
}

AnalyticsSummary _summary({
  required double income,
  required double expenses,
  required double monthlyExpenses,
}) =>
    AnalyticsSummary(
      totalIncome: income,
      totalExpense: expenses,
      savings: 0,
      monthlyExpense: monthlyExpenses,
    );

void main() {
  testWidgets(
      'dashboard renders summary, budget, top categories and recent five',
      (tester) async {
    final now = DateTime.now();
    final previousMonth = DateTime(now.year, now.month - 1, 12);
    DateTime atMinute(int minute) =>
        DateTime(now.year, now.month, now.day, 12, minute);
    final transactions = [
      _transaction(
        id: 'income',
        type: TransactionType.income,
        amount: 2000,
        date: atMinute(10),
        category: 'Salary',
      ),
      _transaction(
        id: 'food',
        type: TransactionType.expense,
        amount: 180,
        date: atMinute(9),
        category: 'Food',
        merchant: 'Market',
      ),
      _transaction(
        id: 'travel',
        type: TransactionType.expense,
        amount: 120,
        date: atMinute(8),
        category: 'Travel',
        merchant: 'Metro',
      ),
      _transaction(
        id: 'bills',
        type: TransactionType.expense,
        amount: 60,
        date: atMinute(7),
        category: 'Bills',
      ),
      _transaction(
        id: 'health',
        type: TransactionType.expense,
        amount: 40,
        date: atMinute(6),
        category: 'Health',
      ),
      _transaction(
        id: 'shopping',
        type: TransactionType.expense,
        amount: 30,
        date: atMinute(5),
        category: 'Shopping',
      ),
      _transaction(
        id: 'older-current',
        type: TransactionType.expense,
        amount: 20,
        date: previousMonth,
        category: 'Other',
      ),
      _transaction(
        id: 'previous',
        type: TransactionType.expense,
        amount: 200,
        date: previousMonth,
        category: 'Food',
      ),
    ];
    var openedTransactions = false;
    await tester.pumpWidget(
      _dashboardApp(
        transactions: transactions,
        summary: _summary(income: 2000, expenses: 650, monthlyExpenses: 450),
        budgets: [
          _budget(
            500,
            '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}',
          ),
        ],
        onViewAll: () => openedTransactions = true,
      ),
    );

    expect(find.text('Good ${_greeting()}, Lenin'), findsOneWidget);
    expect(find.textContaining('${_monthName(now.month)} ${now.year}'),
        findsOneWidget);
    expect(find.text(formatCurrency(1350)), findsWidgets);
    expect(find.text(formatCurrency(2000)), findsWidgets);
    expect(find.text(formatCurrency(650)), findsWidgets);
    expect(find.text('Spent'), findsOneWidget);
    expect(find.textContaining('86.0%'), findsOneWidget);
    expect(find.text('Food'), findsWidgets);
    expect(find.text('Travel'), findsWidgets);
    expect(find.text('Bills'), findsWidgets);
    expect(find.textContaining('42%'), findsOneWidget);
    expect(find.textContaining('28%'), findsOneWidget);
    expect(find.textContaining('Spent 95.5% more'), findsOneWidget);
    expect(find.text('Shopping'), findsNothing);
    expect(find.text('Market'), findsOneWidget);
    expect(find.text('Metro'), findsOneWidget);
    expect(find.text('older-current'), findsNothing);

    await tester.ensureVisible(find.text('View all'));
    await tester.tap(find.text('View all'));
    expect(openedTransactions, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty dashboard shows friendly first-transaction state',
      (tester) async {
    await tester.pumpWidget(
      _dashboardApp(
        transactions: const [],
        summary: _summary(income: 0, expenses: 0, monthlyExpenses: 0),
      ),
    );

    expect(find.text('Start building a clearer picture of your money.'),
        findsOneWidget);
    expect(find.text('Add more transactions to get personalized insights.'),
        findsOneWidget);
    expect(find.text('Your recent activity will appear here.'), findsOneWidget);
    expect(find.text('Add expense'), findsWidgets);
    expect(find.text('₹0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard is responsive at phone size and quick actions render',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime.now();
    var receiptScanLaunched = false;
    var smsScanLaunched = false;
    await tester.pumpWidget(
      _dashboardApp(
        transactions: [
          _transaction(
            id: 'expense',
            type: TransactionType.expense,
            amount: 75,
            date: now,
          ),
        ],
        summary: _summary(income: 100, expenses: 75, monthlyExpenses: 75),
        onScanReceipt: () => receiptScanLaunched = true,
        onScanSms: () => smsScanLaunched = true,
      ),
    );

    await tester.ensureVisible(find.text('Scan receipt'));
    await tester.tap(find.text('Scan receipt'));
    expect(receiptScanLaunched, isTrue);
    await tester.ensureVisible(find.text('Scan SMS'));
    await tester.tap(find.text('Scan SMS'));
    expect(smsScanLaunched, isTrue);
    await tester.ensureVisible(find.text('View all'));
    expect(tester.takeException(), isNull);
  });
}

String _greeting() {
  final hour = DateTime.now().hour;
  if (hour < 12) return 'morning';
  if (hour < 17) return 'afternoon';
  return 'evening';
}

String _monthName(int month) => const [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ][month - 1];
