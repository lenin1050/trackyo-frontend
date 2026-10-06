import 'package:flutter_test/flutter_test.dart';
import 'package:trackyo/trackyo_app.dart';

TransactionRecord _transaction({
  required String id,
  required TransactionType type,
  required double amount,
  required DateTime date,
  String category = 'Food',
}) =>
    TransactionRecord(
      id: id,
      type: type,
      amount: amount,
      category: category,
      description: '',
      merchant: '',
      paymentMethod: 'UPI',
      date: date,
      source: 'manual',
      receiptImage: '',
    );

BudgetRecord _budget({
  required double amount,
  required String month,
  String category = overallBudgetCategory,
}) =>
    BudgetRecord(
      id: 'budget-1',
      category: category,
      amount: amount,
      month: month,
    );

void main() {
  group('calculateMonthlyBudgetStatus', () {
    final currentMonth = DateTime(2026, 10, 5);
    final transactions = [
      _transaction(
        id: 'expense-a',
        type: TransactionType.expense,
        amount: 300,
        date: DateTime(2026, 10, 1),
      ),
      _transaction(
        id: 'expense-b',
        type: TransactionType.expense,
        amount: 200,
        date: DateTime(2026, 10, 31, 23, 59),
        category: 'Travel',
      ),
      _transaction(
        id: 'income',
        type: TransactionType.income,
        amount: 5000,
        date: DateTime(2026, 10, 3),
        category: 'Salary',
      ),
      _transaction(
        id: 'previous-month',
        type: TransactionType.expense,
        amount: 900,
        date: DateTime(2026, 9, 30, 23, 59),
      ),
      _transaction(
        id: 'next-month',
        type: TransactionType.expense,
        amount: 700,
        date: DateTime(2026, 11, 1),
      ),
    ];

    test('calculates current-month total spend across expense categories', () {
      final status = calculateMonthlyBudgetStatus(
        transactions: transactions,
        budgets: [_budget(amount: 1000, month: '2026-10')],
        referenceDate: currentMonth,
      );

      expect(status.spent, 500);
      expect(status.month, '2026-10');
    });

    test('calculates remaining budget and percentage used', () {
      final status = calculateMonthlyBudgetStatus(
        transactions: transactions,
        budgets: [_budget(amount: 1000, month: '2026-10')],
        referenceDate: currentMonth,
      );

      expect(status.limit, 1000);
      expect(status.remaining, 500);
      expect(status.percentUsed, 0.5);
      expect(status.isNearLimit, isFalse);
      expect(status.isExceeded, isFalse);
    });

    test('shows a warning near the budget limit', () {
      final status = calculateMonthlyBudgetStatus(
        transactions: transactions,
        budgets: [_budget(amount: 600, month: '2026-10')],
        referenceDate: currentMonth,
      );

      expect(status.percentUsed, closeTo(0.8333, 0.001));
      expect(status.isNearLimit, isTrue);
      expect(status.isExceeded, isFalse);
    });

    test('reports overspend and negative remaining amount', () {
      final status = calculateMonthlyBudgetStatus(
        transactions: transactions,
        budgets: [_budget(amount: 400, month: '2026-10')],
        referenceDate: currentMonth,
      );

      expect(status.remaining, -100);
      expect(status.percentUsed, 1.25);
      expect(status.isExceeded, isTrue);
      expect(status.isNearLimit, isFalse);
    });

    test('does not apply a different month budget or count other months', () {
      final status = calculateMonthlyBudgetStatus(
        transactions: transactions,
        budgets: [_budget(amount: 1200, month: '2026-09')],
        referenceDate: currentMonth,
      );

      expect(status.isConfigured, isFalse);
      expect(status.spent, 500);
    });

    test('handles no transactions and no configured budget', () {
      final status = calculateMonthlyBudgetStatus(
        transactions: const [],
        budgets: const [],
        referenceDate: currentMonth,
      );

      expect(status.isConfigured, isFalse);
      expect(status.spent, 0);
      expect(status.remaining, 0);
      expect(status.percentUsed, 0);
    });

    test('date-only transactions on month boundaries use their saved month',
        () {
      final status = calculateMonthlyBudgetStatus(
        transactions: [
          _transaction(
            id: 'month-start',
            type: TransactionType.expense,
            amount: 50,
            date: DateTime(2026, 10, 1),
          ),
          _transaction(
            id: 'month-end',
            type: TransactionType.expense,
            amount: 75,
            date: DateTime(2026, 10, 31),
          ),
        ],
        budgets: [_budget(amount: 200, month: '2026-10')],
        referenceDate: currentMonth,
      );

      expect(status.spent, 125);
      expect(status.remaining, 75);
      expect(status.percentUsed, 0.625);
    });
  });

  test('budget JSON restores persistent limit and computed status', () {
    final budget = BudgetRecord.fromJson({
      'id': 'persisted-budget',
      'category': overallBudgetCategory,
      'amount': 20000,
      'month': '2026-10',
      'spent': 12000,
      'remaining': 8000,
      'percentUsed': 0.6,
    });

    expect(budget.id, 'persisted-budget');
    expect(budget.amount, 20000);
    expect(budget.month, '2026-10');
    expect(budget.spent, 12000);
    expect(budget.remaining, 8000);
    expect(budget.percentUsed, 0.6);
  });
}
