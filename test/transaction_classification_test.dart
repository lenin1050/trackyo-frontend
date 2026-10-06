import 'package:flutter_test/flutter_test.dart';
import 'package:trackyo/trackyo_app.dart';

void main() {
  test('expense serialization sends only an expense category', () {
    final transaction = TransactionRecord(
      id: '',
      type: TransactionType.expense,
      amount: 500,
      category: 'Food',
      description: '',
      merchant: 'Cafe',
      paymentMethod: 'UPI',
      date: DateTime(2026, 10, 5),
      source: 'manual',
      receiptImage: '',
    );

    final json = transaction.toJson();
    expect(json['category'], 'Food');
    expect(json['incomeSource'], '');
  });

  test('income serialization sends an income source, not a category', () {
    final transaction = TransactionRecord(
      id: '',
      type: TransactionType.income,
      amount: 30000,
      category: '',
      incomeSource: 'Salary',
      description: '',
      merchant: '',
      paymentMethod: 'Bank Transfer',
      date: DateTime(2026, 10, 5),
      source: 'manual',
      receiptImage: '',
    );

    final json = transaction.toJson();
    expect(json['category'], '');
    expect(json['incomeSource'], 'Salary');
    expect(transaction.classificationLabel, 'Salary');
  });

  test('date-only transactions serialize without a timezone conversion', () {
    final transaction = TransactionRecord(
      id: '',
      type: TransactionType.expense,
      amount: 3130,
      category: 'Food',
      description: '',
      merchant: 'Cafe',
      paymentMethod: 'Card',
      date: DateTime(2026, 7, 25),
      source: 'receipt',
      receiptImage: '',
    );

    final json = transaction.toJson();
    final restored = TransactionRecord.fromJson(json);

    expect(json['date'], '2026-07-25');
    expect(restored.date, DateTime(2026, 7, 25));
    expect(restored.date.isUtc, isFalse);
  });

  test('date-only API response remains the same day at timezone boundaries',
      () {
    final transaction = TransactionRecord.fromJson({
      'type': 'expense',
      'amount': 3130,
      'category': 'Food',
      'source': 'receipt',
      'date': '2026-07-25',
    });

    expect(transaction.date, DateTime(2026, 7, 25));
    expect(transaction.date.day, 25);
  });

  test('SMS transaction serialization retains its full timestamp', () {
    final instant = DateTime.utc(2026, 7, 24, 18, 30);
    final transaction = TransactionRecord.fromJson({
      'type': 'expense',
      'amount': 500,
      'category': 'Food',
      'source': 'sms',
      'date': instant.toIso8601String(),
    });

    expect(transaction.date.isAtSameMomentAs(instant), isTrue);
    expect(
      transaction.toJson()['date'],
      transaction.date.toUtc().toIso8601String(),
    );
  });

  test('legacy income records remain visible using their previous label', () {
    final transaction = TransactionRecord.fromJson({
      'type': 'income',
      'amount': 30000,
      'category': 'Salary',
      'date': '2026-10-05T00:00:00.000Z',
    });

    expect(transaction.classificationLabel, 'Salary');
    expect(transaction.toJson()['incomeSource'], 'Salary');
    expect(transaction.toJson()['category'], '');
  });

  test('SMS fingerprint is retained for duplicate transaction protection', () {
    const fingerprint = '0123456789abcdef';
    final transaction = TransactionRecord.fromJson({
      'type': 'expense',
      'amount': 500,
      'category': 'Food',
      'source': 'sms',
      'smsFingerprint': fingerprint,
      'date': '2026-10-05T00:00:00.000Z',
    });

    expect(transaction.smsFingerprint, fingerprint);
    expect(transaction.toJson()['smsFingerprint'], fingerprint);
  });
}
