import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trackyo/services/receipt_parser.dart';

void main() {
  group('parseReceiptText', () {
    test('OCR timeout completes with a reviewable failure instead of hanging',
        () async {
      final pending = Completer<String>();

      final outcome = await recognizeReceiptText(
        () => pending.future,
        timeout: const Duration(milliseconds: 10),
      );

      expect(outcome.result.amount, isNull);
      expect(outcome.result.merchant, isNull);
      expect(outcome.error, receiptOcrFailureMessage);
    });

    test('OCR exception returns the same manual-review fallback', () async {
      final outcome = await recognizeReceiptText(
        () => Future<String>.error(StateError('OCR unavailable')),
      );

      expect(outcome.result.hasRecognizedDetails, isFalse);
      expect(outcome.error, receiptOcrFailureMessage);
    });

    test('prefers the labeled grand total over an earlier subtotal', () {
      final result = parseReceiptText(
        'Green Cafe\nSubtotal ₹850.00\nTax ₹42.50\nGrand Total: INR 892.50\nDate: 14/03/2025',
      );

      expect(result.merchant, 'Green Cafe');
      expect(result.amount, 892.5);
      expect(result.amountIsLabeled, isTrue);
      expect(result.tax, 42.5);
      expect(result.date, DateTime(2025, 3, 14));
      expect(result.description, contains('Tax'));
    });

    test('regresses Sunrise Foods OCR without reading identifiers as total',
        () {
      final result = parseReceiptText(
        'Sunrise Foods Pvt Ltd\n'
        'Main Road, Maharashtra 941269\n'
        'Contact Number: 6346224470\n'
        'Table: 109\n'
        'Invoice No: INV-2026-778812\n'
        'GSTIN: 27ABCDE1234F1Z5\n'
        'Date: 25/07/2026\n'
        'Item 1 2930.00\n'
        'Item 2 e80.00\n'
        'Item 3 310.00\n'
        'Item 4 2920.00\n'
        'Item 5 23,130.00\n'
        'Subtotal: ₹3,130.00',
      );

      expect(result.merchant, 'Sunrise Foods Pvt Ltd');
      expect(result.date, DateTime(2026, 7, 25));
      expect(result.amount, 3130);
      expect(result.amount, isNot(941269));
      expect(result.amount, isNot(6346224470));
      expect(result.amount, isNot(109));
      expect(
        suggestReceiptCategory(
          merchant: result.merchant,
          items: result.items,
          categories: const ['Food', 'Groceries', 'Other'],
        ),
        'Food',
      );
    });

    test('parses exact physical OCR with detached subtotal and OCR rupee glyphs',
        () {
      const rawOcr = 'Sunrise Foods Pvt Ltd\n'
          '101 Riverfront Lane, 8engaluru,\n'
          'Maharashtra 941269\n'
          'cONTACT NO: 6346224470\n'
          'Date:\n'
          '25/07/2026\n'
          'AECEIPT\n'
          'NO-\n'
          'CUSTOMER\n'
          'PAYMENT\n'
          'MODE-\n'
          '2x Cold Coffee\n'
          'Masala\n'
          'Time:\n'
          '2342\n'
          '1x Paneer Butter\n'
          '3x Cald Coffoo\n'
          '1x Butter Naan\n'
          '4 x\n'
          '2 x Cold Cotfee\n'
          'Cald Coffee\n'
          'SUBTOTAL:\n'
          'Table 109\n'
          'INV-2026-3375\n'
          'Arjun Nair\n'
          'Card\n'
          'e620.00\n'
          '270.00\n'
          '2930.00\n'
          'e80.00\n'
          '310.00\n'
          '2920.00\n'
          '23,130.00';

      final result = parseReceiptText(rawOcr);

      expect(result.merchant, 'Sunrise Foods Pvt Ltd');
      expect(result.date, DateTime(2026, 7, 25));
      expect(result.amount, 3130);
      expect(result.amountIsLabeled, isTrue);
      expect(
        suggestReceiptCategory(
          merchant: result.merchant,
          items: result.items,
          categories: const ['Food', 'Groceries', 'Other'],
        ),
        'Food',
      );
    });

    test('supports labeled Indian amount formats and subtotal fallback', () {
      expect(parseReceiptText('Shop\nTOTAL ₹3,130.00').amount, 3130);
      expect(parseReceiptText('Shop\nGRAND TOTAL: Rs. 3,130.00').amount, 3130);
      expect(parseReceiptText('Shop\nNET TOTAL INR 3130.00').amount, 3130);
      expect(parseReceiptText('Shop\nAMOUNT DUE 3,130.00').amount, 3130);
      expect(parseReceiptText('Shop\nBALANCE DUE: 3130.00').amount, 3130);
      expect(
        parseReceiptText('Shop\nSUBTOTAL\n₹3,130.00').amount,
        3130,
      );
    });

    test('reads OCR-damaged currency markers only beside labeled totals', () {
      expect(parseReceiptText('Shop\nSUBTOTAL: e3,130.00').amount, 3130);
      expect(parseReceiptText('Shop\nGRAND TOTAL: ? 3,130.00').amount, 3130);
      expect(parseReceiptText('Shop\nTOTAL: R 3130').amount, 3130);
      expect(parseReceiptText('Shop\nTOTAL: ₹3130').amount, 3130);
      expect(parseReceiptText('Shop\nTOTAL: Rs 3130/-').amount, 3130);
      expect(parseReceiptText('Shop\nTOTAL: INR 3130.00').amount, 3130);
    });

    test('finds labeled total when OCR flattened the receipt header lines', () {
      final result = parseReceiptText(
        'Market Road 941269 Contact 6346224470 SUBTOTAL: e3,130.00',
      );

      expect(result.amount, 3130);
    });

    test('requires stronger evidence for an amount on the line after a label',
        () {
      expect(parseReceiptText('Shop\nSUBTOTAL\n6346224470').amount, isNull);
      expect(parseReceiptText('Shop\nSUBTOTAL\n941269').amount, isNull);
      expect(parseReceiptText('Shop\nSUBTOTAL\n109').amount, isNull);
      expect(parseReceiptText('Shop\nSUBTOTAL\n₹3,130.00').amount, 3130);
    });

    test('reconciles detached item amount rows with a labeled subtotal', () {
      final result = parseReceiptText(
        'Corner Market\n'
        'SUBTOTAL:\n'
        'ITEMS\n'
        'PAYMENT MODE\n'
        '10.00\n'
        '21.00\n'
        '31.00',
      );

      expect(result.amount, 31);
      expect(result.amountIsLabeled, isTrue);
    });

    test('does not guess detached subtotal from unrelated numeric rows', () {
      expect(
        parseReceiptText(
          'Store\nSUBTOTAL:\nTable 109\nInvoice 941269\nPhone 6346224470',
        ).amount,
        isNull,
      );
      expect(
        parseReceiptText(
          'Store\nSUBTOTAL:\n10.00\n21.00\n33.00',
        ).amount,
        isNull,
      );
    });

    test('prefers final total regardless of subtotal order', () {
      final result = parseReceiptText(
        'Market\nTOTAL: INR 3,250.00\nSUBTOTAL: Rs. 3,130.00',
      );

      expect(result.amount, 3250);
    });

    test('does not interpret contact and identifier numbers as total', () {
      final result = parseReceiptText(
        'Market\n'
        'Phone: 6346224470\n'
        'Table No: 109\n'
        'Invoice No: INV-2026-778812\n'
        'Receipt No: 98231477\n'
        'GSTIN: 27ABCDE1234F1Z5\n'
        'PIN: 400001\n'
        'Account No: 123456789012\n'
        'Transaction Ref: 8820017123',
      );

      expect(result.amount, isNull);
      expect(result.amountIsLabeled, isFalse);
      expect(result.merchant, 'Market');
    });

    test('does not infer a bill amount from an address and postal code', () {
      final result = parseReceiptText(
        'Central Market\n'
        'Maharashtra 941269\n'
        'Plot 14, Main Road\n'
        'Phone: 6346224470\n'
        'Table 109',
      );

      expect(result.amount, isNull);
      expect(result.merchant, 'Central Market');
    });

    test('does not accept an identifier placed after a total label', () {
      final result = parseReceiptText(
        'Store\nTOTAL\nInvoice No: 8877665544\nPhone: 6346224470',
      );

      expect(result.amount, isNull);
    });

    test('prefers a business name over address and contact header lines', () {
      final result = parseReceiptText(
        'Main Street, Downtown\n'
        'Phone: 6346224470\n'
        'Table: 109\n'
        'Sunrise Foods Pvt Ltd\n'
        'Date: 25/07/2026\n'
        'Total: INR 3,130.00',
      );

      expect(result.merchant, 'Sunrise Foods Pvt Ltd');
    });

    test('extracts common named and ISO receipt dates', () {
      expect(
        parseReceiptText('Cafe\nTotal Rs. 125\n21 Mar 2025').date,
        DateTime(2025, 3, 21),
      );
      expect(
        parseReceiptText('Cafe\nTotal ₹125\n2025-03-22').date,
        DateTime(2025, 3, 22),
      );
    });

    test('keeps numeric date-only receipt dates in their calendar timezone', () {
      for (final separator in ['/', '-', '.']) {
        final result = parseReceiptText(
          'Cafe\nDate: 25${separator}07${separator}2026\nTotal ₹50.00',
        );

        expect(result.date, DateTime(2026, 7, 25));
        expect(result.date!.isUtc, isFalse);
      }
    });

    test('date-only receipt parsing is unaffected by UTC day boundaries', () {
      final result = parseReceiptText(
        'Cafe\nDate: 01.01.2026\nTotal ₹50.00',
      );

      expect(result.date, DateTime(2026, 1, 1));
      expect(result.date!.toUtc().toLocal(), DateTime(2026, 1, 1));
    });

    test('does not invent fields when text has no usable receipt details', () {
      final result = parseReceiptText('Thank you for visiting');

      expect(result.amount, isNull);
      expect(result.date, isNull);
      expect(result.merchant, isNull);
      expect(result.isLowConfidence, isTrue);
    });

    test('extracts line items, GST, invoice number and a merchant', () {
      final result = parseReceiptText(
        'Swiggy\n'
        'Veg Burger 250.00\n'
        'Fries 120\n'
        'CGST 10.00\n'
        'SGST 10.00\n'
        'Invoice No: SW-2025/18\n'
        'Total: ₹390.00\n'
        '21 Mar 2025',
      );

      expect(result.merchant, 'Swiggy');
      expect(result.amount, 390);
      expect(result.date, DateTime(2025, 3, 21));
      expect(result.items.map((item) => item.name), ['Veg Burger', 'Fries']);
      expect(result.items.map((item) => item.amount), [250, 120]);
      expect(result.tax, 20);
      expect(result.invoiceNumber, 'SW-2025/18');
      expect(result.description, contains('Veg Burger'));
    });

    test('calculates itemized total only from monetary purchased-item rows',
        () {
      final result = parseReceiptText(
        'City Supermarket\n'
        'Milk 2 x Rs. 60.00\n'
        'Bread ₹45.00\n'
        'Apples 120.00\n'
        'Table 109\n'
        'Phone 6346224470\n'
        'GSTIN 27ABCDE1234F1Z5',
      );

      expect(result.amount, 225);
      expect(result.amountIsLabeled, isFalse);
      expect(result.items.map((item) => item.amount), [60, 45, 120]);
    });

    test(
        'does not use quantities or arbitrary identifier numbers as item prices',
        () {
      final result = parseReceiptText(
        'Restaurant\n'
        'Table 109\n'
        '2 x Tea\n'
        '2 x 100.00\n'
        'Contact 6346224470\n'
        'Invoice No 941269',
      );

      expect(result.amount, isNull);
      expect(result.items, isEmpty);
    });

    test('does not guess a total from an unlabeled item price', () {
      final result = parseReceiptText('Corner Cafe\nCoffee ₹90.00');

      expect(result.amount, isNull);
      expect(result.amountIsLabeled, isFalse);
      expect(result.isLowConfidence, isTrue);
    });

    test('suggests a category from merchant or receipt item names', () {
      const categories = ['Food', 'Groceries', 'Travel', 'Other'];

      expect(
        suggestReceiptCategory(
          merchant: 'Swiggy',
          items: const [],
          categories: categories,
        ),
        'Food',
      );
      expect(
        suggestReceiptCategory(
          merchant: 'Local Market',
          items: const [ReceiptLineItem(name: 'Fresh vegetables', amount: 80)],
          categories: categories,
        ),
        'Groceries',
      );
      expect(
        suggestReceiptCategory(
          merchant: 'Unknown Vendor',
          items: const [],
          categories: categories,
        ),
        isNull,
      );
    });
  });
}
