import 'dart:async';

class ReceiptLineItem {
  const ReceiptLineItem({required this.name, required this.amount});

  final String name;
  final double amount;
}

class ReceiptScanResult {
  const ReceiptScanResult({
    required this.amount,
    required this.amountIsLabeled,
    required this.merchant,
    required this.date,
    required this.description,
    required this.items,
    required this.tax,
    required this.invoiceNumber,
  });

  final double? amount;
  final bool amountIsLabeled;
  final String? merchant;
  final DateTime? date;
  final String description;
  final List<ReceiptLineItem> items;
  final double? tax;
  final String? invoiceNumber;

  bool get hasRecognizedDetails =>
      amount != null ||
      merchant != null ||
      date != null ||
      items.isNotEmpty ||
      tax != null ||
      invoiceNumber != null;

  bool get isLowConfidence =>
      amount == null || !amountIsLabeled || merchant == null || date == null;
}

class ReceiptOcrOutcome {
  const ReceiptOcrOutcome({required this.result, required this.error});

  final ReceiptScanResult result;
  final String error;
}

class _ReceiptAmount {
  const _ReceiptAmount(this.value, {required this.isLabeled});

  final double? value;
  final bool isLabeled;
}

const receiptOcrFailureMessage =
    'Unable to read this receipt. Please review or enter the details manually.';

Future<ReceiptOcrOutcome> recognizeReceiptText(
  Future<String> Function() recognize, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  try {
    final result = parseReceiptText(await recognize().timeout(timeout));
    if (!result.hasRecognizedDetails) {
      return const ReceiptOcrOutcome(
        result: ReceiptScanResult(
          amount: null,
          amountIsLabeled: false,
          merchant: null,
          date: null,
          description: '',
          items: [],
          tax: null,
          invoiceNumber: null,
        ),
        error: receiptOcrFailureMessage,
      );
    }
    return ReceiptOcrOutcome(result: result, error: '');
  } catch (_) {
    return const ReceiptOcrOutcome(
      result: ReceiptScanResult(
        amount: null,
        amountIsLabeled: false,
        merchant: null,
        date: null,
        description: '',
        items: [],
        tax: null,
        invoiceNumber: null,
      ),
      error: receiptOcrFailureMessage,
    );
  }
}

ReceiptScanResult parseReceiptText(String text) {
  final normalized = text.trim();
  if (normalized.isEmpty) {
    return const ReceiptScanResult(
      amount: null,
      amountIsLabeled: false,
      merchant: null,
      date: null,
      description: '',
      items: [],
      tax: null,
      invoiceNumber: null,
    );
  }

  final lines = normalized
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final items = _readItems(lines);
  final tax = _readTax(normalized);
  final invoiceNumber = _readInvoiceNumber(normalized);
  final details = <String>[
    for (final item in items) '${item.name} ${_formatAmount(item.amount)}',
    if (tax != null) 'Tax ${_formatAmount(tax)}',
    if (invoiceNumber != null) 'Bill no. $invoiceNumber',
  ];
  final description = details.isNotEmpty
      ? details.join(' • ')
      : normalized.length > 500
          ? normalized.substring(0, 500)
          : normalized;

  final detectedAmount = _readBillAmount(lines);
  return ReceiptScanResult(
    amount: detectedAmount.value,
    amountIsLabeled: detectedAmount.isLabeled,
    merchant: _readMerchant(lines),
    date: _readDate(normalized),
    description: description,
    items: items,
    tax: tax,
    invoiceNumber: invoiceNumber,
  );
}

String? suggestReceiptCategory({
  required String? merchant,
  required List<ReceiptLineItem> items,
  required List<String> categories,
}) {
  final text = [
    if (merchant != null) merchant,
    for (final item in items) item.name,
  ].join(' ').toLowerCase();
  if (text.isEmpty) return null;

  const keywords = <String, List<String>>{
    'Food': [
      'restaurant',
      'cafe',
      'coffee',
      'food',
      'swiggy',
      'zomato',
      'pizza',
      'burger',
      'bakery',
      'dining',
    ],
    'Groceries': [
      'grocery',
      'groceries',
      'supermarket',
      'vegetable',
      'fruit',
      'milk',
      'market',
    ],
    'Travel': ['uber', 'ola', 'flight', 'train', 'bus', 'metro', 'airline'],
    'Fuel': ['petrol', 'diesel', 'fuel', 'indian oil', 'bharat petroleum'],
    'Shopping': ['shopping', 'amazon', 'flipkart', 'myntra', 'retail', 'store'],
    'Bills': ['electricity', 'water bill', 'internet', 'broadband', 'utility'],
    'Entertainment': [
      'cinema',
      'movie',
      'netflix',
      'spotify',
      'theatre',
      'ticket'
    ],
    'Health': [
      'pharmacy',
      'medical',
      'hospital',
      'clinic',
      'medicine',
      'health'
    ],
    'Education': [
      'school',
      'college',
      'bookstore',
      'education',
      'tuition',
      'course'
    ],
  };
  for (final category in categories) {
    final candidates = keywords[category];
    if (candidates != null && candidates.any(text.contains)) return category;
  }
  return null;
}

_ReceiptAmount _readBillAmount(List<String> lines) {
  const finalTotalLabels = [
    r'(?:grand\s+total|total\s+payable)',
    r'(?:net\s+total|net\s+amount)',
    r'(?:amount\s+due|balance\s+due|amount\s+paid)',
    r'total\s+amount',
    r'final\s+total',
    r'total',
  ];
  for (final label in finalTotalLabels) {
    final amount = _readLabeledAmount(lines, label);
    if (amount != null) return _ReceiptAmount(amount, isLabeled: true);
  }

  final subtotal = _readLabeledAmount(lines, r'sub\s*total|subtotal');
  if (subtotal != null) return _ReceiptAmount(subtotal, isLabeled: true);
  final detachedSubtotal = _readDetachedSubtotalAmount(lines);
  if (detachedSubtotal != null) {
    return _ReceiptAmount(detachedSubtotal, isLabeled: true);
  }

  final items = _readItems(lines);
  if (items.length >= 2) {
    final itemizedTotal =
        items.fold<double>(0, (total, item) => total + item.amount);
    if (itemizedTotal > 0) {
      return _ReceiptAmount(itemizedTotal, isLabeled: false);
    }
  }
  return const _ReceiptAmount(null, isLabeled: false);
}

double? _readDetachedSubtotalAmount(List<String> lines) {
  final subtotalIndex = lines.lastIndexWhere(
    (line) => RegExp(r'\bsub\s*total\b', caseSensitive: false).hasMatch(line),
  );
  if (subtotalIndex < 0) return null;

  final rows = <List<int>>[];
  for (final line in lines.skip(subtotalIndex + 1)) {
    if (_readDate(line) != null || _isIdentifierLine(line)) continue;
    final trimmed = line.trim();
    final hasMonetaryFormat = RegExp(
          r'(?:\.\d{1,2}\s*$|^(?:₹|INR\b|Rs\.?|e|[?£|~])\s*)',
          caseSensitive: false,
        ).hasMatch(trimmed) ||
        RegExp(r'^\d{1,3}(?:,\d{2})*,\d{3}\s*$').hasMatch(trimmed);
    if (!hasMonetaryFormat) continue;

    final variants = <int>{};
    final amount = _parseLabeledMoney(trimmed);
    if (amount != null) variants.add((amount * 100).round());

    // Some OCR engines recognize the rupee glyph as a leading "2".
    if (trimmed.startsWith('2')) {
      final withoutGlyph = _parseLabeledMoney(trimmed.substring(1));
      if (withoutGlyph != null) {
        variants.add((withoutGlyph * 100).round());
      }
    }
    if (variants.isNotEmpty) rows.add(variants.toList());
  }

  if (rows.length < 3) return null;
  final itemRows = rows.sublist(0, rows.length - 1);
  final subtotalValues = rows.last;
  var possibleSums = <int, int>{0: 1};
  for (final itemRow in itemRows) {
    final nextSums = <int, int>{};
    for (final entry in possibleSums.entries) {
      for (final amount in itemRow) {
        final sum = entry.key + amount;
        nextSums[sum] =
            ((nextSums[sum] ?? 0) + entry.value).clamp(0, 2);
      }
    }
    if (nextSums.length > 5000) return null;
    possibleSums = nextSums;
  }

  final matchingSubtotals = subtotalValues
      .where(possibleSums.containsKey)
      .map((value) => value / 100)
      .toSet();
  return matchingSubtotals.length == 1 ? matchingSubtotals.single : null;
}

double? _readLabeledAmount(List<String> lines, String label) {
  final labelLine = RegExp(
    '\\b(?:$label)\\b(?:\\s*\\([^)]{0,32}\\))?'
    r'(?:\s*[:=—-]\s*|\s+)?(.*)$',
    caseSensitive: false,
  );
  for (var index = lines.length - 1; index >= 0; index--) {
    final match = labelLine.firstMatch(lines[index]);
    if (match == null) continue;
    final remainder = (match.group(1) ?? '').trim();
    final sameLineAmount = _parseLabeledMoney(remainder);
    if (sameLineAmount != null) return sameLineAmount;
    if (remainder.isNotEmpty) continue;
    if (index + 1 >= lines.length) continue;
    final nextLine = lines[index + 1].trim();
    final isSubtotal = RegExp(r'sub\s*total|subtotal', caseSensitive: false)
        .hasMatch(label);
    final hasLaterMoney = lines
        .skip(index + 2)
        .any((line) => _parseLabeledMoney(line) != null);
    if (isSubtotal &&
        !_hasExplicitCurrencyMarker(nextLine) &&
        hasLaterMoney) {
      continue;
    }
    final nextLineAmount = _parseLabeledMoney(
      nextLine,
      requireCurrencyEvidence: true,
    );
    if (nextLineAmount != null) return nextLineAmount;
  }
  return null;
}

double? _parseLabeledMoney(
  String value, {
  bool requireCurrencyEvidence = false,
}) {
  final normalized = value
      .replaceAll('\u00a0', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(RegExp(r'\s*/-\s*$'), '');
  final hasCurrencyEvidence = RegExp(
        r'^(?:₹|INR\b|Rs\.?|R\b|[eE?£|~])|(?:\bINR|\bRs\.?)\s*$',
        caseSensitive: false,
      ).hasMatch(normalized) ||
      RegExp(r'\d[\d,]*[,.]\d{1,2}$').hasMatch(normalized) ||
      RegExp(r'\d{1,3}(?:,\d{2})*,\d{3}$').hasMatch(normalized);
  if (requireCurrencyEvidence && !hasCurrencyEvidence) return null;

  final match = RegExp(
    r'^(?:(?:₹|INR|Rs\.?|R\.?|[eE?£|~])\s*)?((?:\d{1,3}(?:,\d{3})+|\d{1,3}(?:,\d{2})*,\d{3}|\d+)(?:\.\d{1,2})?)(?:\s*(?:INR|Rs\.?))?$',
    caseSensitive: false,
  ).firstMatch(normalized);
  if (match == null) return null;
  final amount = double.tryParse(match.group(1)!.replaceAll(',', ''));
  return amount != null && amount > 0 ? amount : null;
}

bool _hasExplicitCurrencyMarker(String value) => RegExp(
      r'^(?:₹|INR\b|Rs\.?|e|[?£|~])',
      caseSensitive: false,
    ).hasMatch(value.trim());

List<ReceiptLineItem> _readItems(List<String> lines) {
  final items = <ReceiptLineItem>[];
  final amountAtEnd = RegExp(
    r'(.+?)\s+(₹|INR|Rs\.?)?\s*((?:\d{1,3}(?:,\d{3})+|\d{1,3}(?:,\d{2})*,\d{3}|\d+)(?:\.\d{1,2})?)\s*(INR|Rs\.?)?\s*$',
    caseSensitive: false,
  );
  for (final line in lines) {
    if (_readDate(line) != null || _isIdentifierLine(line)) continue;
    final match = amountAtEnd.firstMatch(line);
    if (match == null) continue;
    final amountText = match.group(3)!;
    final hasCurrency = match.group(2) != null || match.group(4) != null;
    final hasDecimal = RegExp(r'\.\d{1,2}$').hasMatch(amountText);
    final hasThousandsGrouping = RegExp(
      r'^\d{1,3}(?:,\d{2})*,\d{3}(?:\.\d{1,2})?$',
    ).hasMatch(amountText);
    final bareAmount = double.tryParse(amountText.replaceAll(',', ''));
    final hasPlausibleBareItemPrice = !hasCurrency &&
        !hasDecimal &&
        !hasThousandsGrouping &&
        bareAmount != null &&
        bareAmount <= 9999;
    if (!hasCurrency &&
        !hasDecimal &&
        !hasThousandsGrouping &&
        !hasPlausibleBareItemPrice) {
      continue;
    }
    final name = match.group(1)!.trim().replaceAll(RegExp(r'[\s:*-]+$'), '');
    final amount = double.tryParse(amountText.replaceAll(',', ''));
    if (name.length < 2 ||
        RegExp(r'^\d+\s*[x×]$', caseSensitive: false).hasMatch(name) ||
        !RegExp(r'[A-Za-z]').hasMatch(name) ||
        _isAddressOrLocationLine(name) ||
        amount == null ||
        amount <= 0 ||
        RegExp(
          r'\b(?:subtotal|grand\s+total|total|tax|gst|cgst|sgst|invoice|bill\s*(?:no|number)|date|change|cash|paid)\b',
          caseSensitive: false,
        ).hasMatch(name)) {
      continue;
    }
    items.add(ReceiptLineItem(name: name, amount: amount));
  }
  return items;
}

double? _readTax(String text) {
  final matches = RegExp(
    r'\b(?:gst|cgst|sgst|tax)\b(?:\s*(?:amount|total))?\s*[:\-]?\s*(?:₹|INR|Rs\.?)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
    caseSensitive: false,
  );
  final entries = matches
      .allMatches(text)
      .map((match) => (
            label: match
                .group(0)!
                .trimLeft()
                .split(RegExp(r'\s|:|-'))
                .first
                .toLowerCase(),
            amount: double.tryParse(match.group(1)!.replaceAll(',', '')),
          ))
      .where((entry) => entry.amount != null && entry.amount! > 0)
      .toList();
  final components = entries
      .where((entry) => entry.label == 'cgst' || entry.label == 'sgst')
      .map((entry) => entry.amount!)
      .toList();
  if (components.isNotEmpty) {
    return components.fold<double>(0, (sum, value) => sum + value);
  }
  if (entries.isEmpty) return null;
  return entries
      .map((entry) => entry.amount!)
      .reduce((left, right) => left > right ? left : right);
}

String? _readInvoiceNumber(String text) {
  final match = RegExp(
    r'\b(?:invoice|bill|receipt)\s*(?:no\.?|number|#)\s*[:#-]?\s*([A-Z0-9][A-Z0-9/-]{2,})',
    caseSensitive: false,
  ).firstMatch(text);
  return match?.group(1);
}

String? _readMerchant(List<String> lines) {
  final candidates = <(int, String)>[];
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (!_isMerchantLine(line)) continue;
    var score = 0;
    if (RegExp(
      r'\b(?:pvt\.?\s*ltd\.?|private\s+limited|limited|inc\.?|llp|llc|gmbh)\b',
      caseSensitive: false,
    ).hasMatch(line)) {
      score += 12;
    }
    if (RegExp(
      r'\b(?:restaurant|cafe|hotel|supermarket|pharmacy|clinic|hospital|store|mart|foods?|petrol|fuel|market|bakery|services?)\b',
      caseSensitive: false,
    ).hasMatch(line)) {
      score += 5;
    }
    if (RegExp(r"^[A-Z][A-Z0-9 &.'-]{2,}$").hasMatch(line)) score += 2;
    score -= index.clamp(0, 8).toInt();
    score +=
        line.replaceAll(RegExp(r'[^A-Za-z]'), '').length.clamp(0, 40) ~/ 12;
    candidates.add((score, line));
  }
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => b.$1.compareTo(a.$1));
  return candidates.first.$2;
}

bool _isIdentifierLine(String line) =>
    RegExp(
      r'\b(?:phone|mobile|contact|telephone|tel|table|invoice|receipt|bill\s*(?:no|number|#)|gstin|gst\s*(?:no|number|in)|tax\s*id|vat\s*(?:no|number)|pan\s*(?:no|number)|pin\s*code|postal\s*code|account\s*(?:no|number)|customer\s*id|order\s*id|reference|ref(?:erence)?\s*(?:no|number)|txn\s*(?:id|no)|transaction\s*id|cashier|terminal\s*id|auth(?:orization)?\s*code)\b',
      caseSensitive: false,
    ).hasMatch(line) ||
    RegExp(r'\b\d{7,}\b').hasMatch(line);

bool _isAddressOrLocationLine(String line) =>
    RegExp(
      r'\b(?:address|street|road|avenue|lane|highway|district|state|pin\s*code|postal\s*code|zipcode|near|opposite|sector|phase|plot\s*no|shop\s*no|maharashtra|karnataka|gujarat|rajasthan|delhi|telangana|tamil\s*nadu|uttar\s*pradesh|west\s*bengal|madhya\s*pradesh|kerala|punjab|haryana|bihar|odisha|assam)\b',
      caseSensitive: false,
    ).hasMatch(line) ||
    RegExp(r'\b\d{5,6}\b').hasMatch(line);

bool _isMerchantLine(String line) {
  if (!RegExp(r'[A-Za-z]').hasMatch(line) ||
      RegExp(r'^[\d\s₹.,/-]+$').hasMatch(line)) {
    return false;
  }
  if (_isIdentifierLine(line) ||
      _readDate(line) != null ||
      _isAddressOrLocationLine(line)) {
    return false;
  }
  if (RegExp(r'\s+(?:₹|INR|Rs\.?)?\s*[0-9][0-9,]*(?:\.[0-9]{1,2})?\s*$',
          caseSensitive: false)
      .hasMatch(line)) {
    return false;
  }
  return !RegExp(
    r'^(?:tax\s+invoice|invoice|receipt|bill|grand\s+total|total|subtotal|date|time|gst|cgst|sgst|cashier|phone|mobile|www\.|thank\s+you)\b',
    caseSensitive: false,
  ).hasMatch(line);
}

DateTime? _readDate(String text) {
  final isoDate = RegExp(r'\b(\d{4})-(\d{1,2})-(\d{1,2})\b').firstMatch(text);
  if (isoDate != null) {
    return _validDate(
      int.parse(isoDate.group(1)!),
      int.parse(isoDate.group(2)!),
      int.parse(isoDate.group(3)!),
    );
  }

  final numericDate =
      RegExp(r'\b(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})\b').firstMatch(text);
  if (numericDate != null) {
    final year = int.parse(numericDate.group(3)!);
    return _validDate(
      year < 100 ? 2000 + year : year,
      int.parse(numericDate.group(2)!),
      int.parse(numericDate.group(1)!),
    );
  }

  const months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };
  final namedDate = RegExp(r'\b(\d{1,2})\s+([A-Za-z]{3,9})\.?,?\s+(\d{4})\b')
      .firstMatch(text);
  if (namedDate != null) {
    final monthName = namedDate.group(2)!.toLowerCase().substring(0, 3);
    final month = months[monthName];
    if (month != null) {
      return _validDate(
        int.parse(namedDate.group(3)!),
        month,
        int.parse(namedDate.group(1)!),
      );
    }
  }

  final namedDateFirst =
      RegExp(r'\b([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})\b')
          .firstMatch(text);
  if (namedDateFirst != null) {
    final monthName = namedDateFirst.group(1)!.toLowerCase().substring(0, 3);
    final month = months[monthName];
    if (month != null) {
      return _validDate(
        int.parse(namedDateFirst.group(3)!),
        month,
        int.parse(namedDateFirst.group(2)!),
      );
    }
  }
  return null;
}

DateTime? _validDate(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return null;
  return date;
}

String _formatAmount(double amount) => amount == amount.roundToDouble()
    ? amount.toStringAsFixed(0)
    : amount.toStringAsFixed(2);
