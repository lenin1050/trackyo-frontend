import 'package:flutter_test/flutter_test.dart';
import 'package:trackyo/services/sms_transaction_parser.dart';

void main() {
  group('parseSmsTransaction', () {
    test('parses a UPI debit, amount, merchant and inbox timestamp', () {
      final transaction = parseSmsTransaction({
        'address': 'BANKXX',
        'body':
            'Rs. 1,250.00 debited from A/c XX1234 for UPI payment to Zomato on 2025-03-14.',
        'date': 1741971600000,
      });

      expect(transaction?.amount, 1250);
      expect(transaction?.type, 'expense');
      expect(transaction?.merchant, 'Zomato');
      expect(transaction?.paymentMethod, 'UPI');
      expect(transaction?.service, 'BANKXX');
      expect(
        transaction?.date,
        DateTime.fromMillisecondsSinceEpoch(1741971600000),
      );
    });

    test('parses UPI IDs and credits while retaining a useful merchant', () {
      final transaction = parseSmsTransaction({
        'address': 'BANKXX',
        'body': 'INR 8,500 credited from Acme Corp to your account via NEFT.',
        'date': 1741971600000,
      });

      expect(transaction?.amount, 8500);
      expect(transaction?.type, 'income');
      expect(transaction?.merchant, 'Acme Corp');
      expect(transaction?.paymentMethod, 'NEFT');
      expect(transaction?.service, 'BANKXX');
    });

    test('parses a debit with merchant at the end and extracts its reference',
        () {
      final transaction = parseSmsTransaction({
        'address': 'HDFCBK',
        'body':
            'Your account has been debited by Rs.500 at XYZ Store. UPI Ref 518293746.',
        'date': 1741971600000,
      });

      expect(transaction?.type, 'expense');
      expect(transaction?.amount, 500);
      expect(transaction?.merchant, 'XYZ Store');
      expect(transaction?.reference, '518293746');
      expect(transaction?.service, 'HDFCBK');
    });

    test(
        'does not mistake a later available balance for the transaction amount',
        () {
      final transaction = parseSmsTransaction({
        'address': 'BANKXX',
        'body':
            'Rs.500 debited from your account at XYZ Store.\nAvailable balance Rs.4,500',
        'date': 1741971600000,
      });

      expect(transaction?.amount, 500);
      expect(transaction?.merchant, 'XYZ Store');
    });

    test('parses a PhonePe UPI payment and stable message fingerprint', () {
      final message = {
        'address': 'PHONEPE',
        'body': 'You paid Rs 240 to Cafe Blue via UPI. UTR: UPI12345678',
        'date': 1741971600000,
      };
      final first = parseSmsTransaction(message);
      final second = parseSmsTransaction(Map.of(message));

      expect(first?.type, 'expense');
      expect(first?.amount, 240);
      expect(first?.merchant, 'Cafe Blue');
      expect(first?.paymentMethod, 'UPI');
      expect(first?.service, 'PhonePe');
      expect(first?.reference, 'UPI12345678');
      expect(first?.fingerprint, hasLength(16));
      expect(first?.fingerprint, second?.fingerprint);
    });

    test('ignores messages without a transaction verb or usable amount', () {
      expect(
        parseSmsTransaction({
          'address': 'BANKXX',
          'body': 'Available balance INR 4,000',
          'date': 1741971600000,
        }),
        isNull,
      );
      expect(
        parseSmsTransaction({
          'address': 'BANKXX',
          'body': 'Your transaction was successful.',
          'date': 1741971600000,
        }),
        isNull,
      );
      expect(
        parseSmsTransaction({
          'address': 'BANKXX',
          'body': 'Your account balance is INR 4,000.',
          'date': 1741971600000,
        }),
        isNull,
      );
      expect(
        parseSmsTransaction({
          'address': 'BANKXX',
          'body': 'OTP 492031 for your bank transaction. Rs.500 paid.',
          'date': 1741971600000,
        }),
        isNull,
      );
      expect(
        parseSmsTransaction({
          'address': 'PROMO',
          'body':
              'Congratulations! Pay Rs.500 via UPI to claim a limited time offer.',
          'date': 1741971600000,
        }),
        isNull,
      );
      expect(
        parseSmsTransaction({
          'address': '+919999999999',
          'body': 'I paid Rs.500 yesterday, thanks.',
          'date': 1741971600000,
        }),
        isNull,
      );
      expect(parseSmsTransaction({'body': '', 'date': 'bad'}), isNull);
    });

    test('same SMS details hash identically and changed details differ', () {
      final first = smsFingerprint(
        sender: 'BANKXX',
        body: 'Rs.500 debited for UPI',
        timestamp: 1741971600000,
      );
      final normalizedSame = smsFingerprint(
        sender: ' bankxx ',
        body: '  RS.500   DEBITED FOR UPI ',
        timestamp: 1741971600000,
      );
      final different = smsFingerprint(
        sender: 'BANKXX',
        body: 'Rs.500 debited for UPI',
        timestamp: 1741971600001,
      );

      expect(first, normalizedSame);
      expect(first, isNot(different));
    });

    test('uses Android SMS row ID for a stable message fingerprint', () {
      final first = parseSmsTransaction({
        'id': '84721',
        'address': 'BANKXX',
        'body': 'Rs.500 debited from your account at XYZ Store via UPI.',
        'date': 1741971600000,
      });
      final editedBodySameSmsId = parseSmsTransaction({
        'id': '84721',
        'address': 'BANKXX',
        'body':
            'Rs.500 debited from your account at XYZ Store via UPI. Thank you.',
        'date': 1741971600000,
      });
      final differentSmsId = parseSmsTransaction({
        'id': '84722',
        'address': 'BANKXX',
        'body': 'Rs.500 debited from your account at XYZ Store via UPI.',
        'date': 1741971600000,
      });

      expect(first?.fingerprint, editedBodySameSmsId?.fingerprint);
      expect(first?.fingerprint, isNot(differentSmsId?.fingerprint));
      expect(first?.fingerprint, isNot(first?.contentFingerprint));
    });

    test('suggests only an existing income source and has a safe fallback', () {
      const sources = ['Salary', 'Freelance', 'Business', 'Other'];

      expect(
        suggestSmsIncomeSource(
          message: 'Monthly salary credited to your account',
          incomeSources: sources,
        ),
        'Salary',
      );
      expect(
        suggestSmsIncomeSource(
          message: 'Payment credited to your account',
          incomeSources: sources,
        ),
        'Other',
      );
      expect(
        suggestSmsIncomeSource(message: 'salary', incomeSources: const []),
        '',
      );
    });
  });
}
