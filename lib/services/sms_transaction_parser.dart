import 'dart:convert';

class ParsedSmsTransaction {
  const ParsedSmsTransaction({
    required this.amount,
    required this.type,
    required this.merchant,
    required this.date,
    required this.message,
    required this.sender,
    required this.paymentMethod,
    required this.service,
    required this.reference,
    required this.fingerprint,
    required this.contentFingerprint,
  });

  final double amount;
  final String type;
  final String merchant;
  final DateTime date;
  final String message;
  final String sender;
  final String paymentMethod;
  final String service;
  final String reference;
  final String fingerprint;
  final String contentFingerprint;
}

ParsedSmsTransaction? parseSmsTransaction(Map<String, dynamic> sms) {
  final body = (sms['body'] ?? '').toString().trim();
  final sender = (sms['address'] ?? '').toString().trim();
  if (body.isEmpty ||
      _isNonTransactionMessage(body) ||
      !_isTransactionMessage(body)) {
    return null;
  }
  final isIncome = _transactionType(body);
  if (isIncome == null) return null;
  final amount = _readTransactionAmount(body);
  if (amount == null) return null;

  final timestamp = sms['date'] is num
      ? (sms['date'] as num).toInt()
      : int.tryParse('${sms['date']}');
  final date = timestamp == null || timestamp <= 0
      ? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(timestamp);
  final reference = _readReference(body);
  final paymentMethod = _readPaymentMethod(body);
  final service = _readService(body, sender, paymentMethod);
  return ParsedSmsTransaction(
    amount: amount,
    type: isIncome ? 'income' : 'expense',
    merchant: _readMerchant(body, isIncome) ?? service,
    date: date,
    message: body,
    sender: sender,
    paymentMethod: paymentMethod,
    service: service,
    reference: reference,
    fingerprint: smsFingerprint(
      sender: sender,
      body: body,
      timestamp: timestamp,
      messageId: sms['id']?.toString(),
    ),
    contentFingerprint:
        smsFingerprint(sender: sender, body: body, timestamp: timestamp),
  );
}

bool _isTransactionMessage(String body) =>
    RegExp(
      r'\b(?:debited|credited|withdrawn|withdrawal|spent|paid|purchase|received|deposit|transferred|transfer|sent)\b',
      caseSensitive: false,
    ).hasMatch(body) &&
    RegExp(
      r'\b(?:account|a/c|card|upi|imps|neft|rtgs|transaction|payment|bank|wallet|transfer)\b',
      caseSensitive: false,
    ).hasMatch(body);

bool _isNonTransactionMessage(String body) => RegExp(
      r'\b(?:otp|one[- ]time password|verification code|promo(?:tion)?|offer|unsubscribe|click here|limited time|win a|congratulations)\b',
      caseSensitive: false,
    ).hasMatch(body);

bool? _transactionType(String body) {
  final credit = RegExp(
    r'\b(credited|credit|received|deposit)\b',
    caseSensitive: false,
  ).hasMatch(body);
  final debit = RegExp(
    r'\b(debited|debit|withdrawn|withdrawal|spent|paid|purchase|transferred|transfer|sent)\b',
    caseSensitive: false,
  ).hasMatch(body);
  if (credit && debit) return null;
  if (credit) return true;
  if (debit) return false;
  return null;
}

double? _readTransactionAmount(String body) {
  final amounts = RegExp(
    r'(?:INR|Rs\.?|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)|([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*(?:INR|Rs\.?|₹)',
    caseSensitive: false,
  ).allMatches(body);
  for (final match in amounts) {
    final lineStart = body.lastIndexOf('\n', match.start) + 1;
    final nextLine = body.indexOf('\n', match.end);
    final lineEnd = nextLine == -1 ? body.length : nextLine;
    final before = body.substring(lineStart, match.start);
    final after = body.substring(match.end, lineEnd);
    if (RegExp(r'\b(?:balance|available|limit|minimum|due|outstanding)\b',
                caseSensitive: false)
            .hasMatch(before) ||
        RegExp(r'^\s*(?:balance|available|limit|minimum|due|outstanding)\b',
                caseSensitive: false)
            .hasMatch(after)) {
      continue;
    }
    final amount = double.tryParse(
      (match.group(1) ?? match.group(2) ?? '').replaceAll(',', ''),
    );
    if (amount != null && amount > 0) return amount;
  }
  return null;
}

String? _readMerchant(String body, bool isIncome) {
  final phrases = isIncome
      ? ['merchant', 'beneficiary', 'from', 'at', 'to']
      : ['merchant', 'beneficiary', 'paid to', 'sent to', 'to', 'at'];
  for (final phrase in phrases) {
    final match = RegExp(
      '\\b${RegExp.escape(phrase)}\\s+(?:VPA\\s+)?([A-Za-z][A-Za-z0-9 &._\\x27-]{1,47}?)(?=\\s+(?:on|via|using|ref|txn|transaction|for|from|to|a/c|account|through|upi|by|with|INR|Rs\\.?)\\b|\\s*₹|[,;.]|\$)',
      caseSensitive: false,
    ).firstMatch(body);
    final candidate = match?.group(1)?.trim();
    if (candidate != null && !_isAccountLabel(candidate)) return candidate;
  }

  final vpa = RegExp(
    r'\b(?:VPA|UPI(?:\s+ID)?)\s*[:/-]?\s*([A-Za-z0-9._-]+@[A-Za-z0-9.-]+)',
    caseSensitive: false,
  ).firstMatch(body);
  return vpa?.group(1)?.trim();
}

String _readReference(String body) =>
    RegExp(
      r'\b(?:UPI\s*(?:ref(?:erence)?|ID)|(?:UTR|RRN|reference|ref(?:erence)?|txn(?:\s*id)?|transaction\s*id))\s*[:#-]?\s*([A-Z0-9/-]{5,})',
      caseSensitive: false,
    ).firstMatch(body)?.group(1) ??
    '';

String _readPaymentMethod(String body) {
  final match = RegExp(r'\b(UPI|IMPS|NEFT|RTGS|ATM|POS|CARD|WALLET)\b',
          caseSensitive: false)
      .firstMatch(body);
  return match?.group(1)?.toUpperCase() ?? 'Bank';
}

String _readService(String body, String sender, String method) {
  final servicePattern = RegExp(
    r'\b(Google\s*Pay|PhonePe|Paytm|Amazon\s*Pay|BHIM|Visa|Mastercard)\b',
    caseSensitive: false,
  );
  final service = servicePattern.firstMatch(body)?.group(1) ??
      servicePattern.firstMatch(sender)?.group(1);
  if (service != null) {
    const displayNames = {
      'googlepay': 'Google Pay',
      'phonepe': 'PhonePe',
      'paytm': 'Paytm',
      'amazonpay': 'Amazon Pay',
      'bhim': 'BHIM',
      'visa': 'Visa',
      'mastercard': 'Mastercard',
    };
    return displayNames[service.replaceAll(RegExp(r'\s+'), '').toLowerCase()] ??
        service;
  }
  final cleanedSender = sender.replaceAll(RegExp(r'[^A-Za-z0-9 ]'), '').trim();
  if (cleanedSender.isNotEmpty && cleanedSender.length <= 24) {
    return cleanedSender;
  }
  return method == 'Bank' ? 'Bank' : method;
}

String smsFingerprint({
  required String sender,
  required String body,
  required int? timestamp,
  String? messageId,
}) {
  final normalized = messageId != null && messageId.trim().isNotEmpty
      ? '${sender.trim().toLowerCase()}|sms-id:${messageId.trim()}'
      : '${sender.trim().toLowerCase()}|'
          '${body.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase()}|'
          '${timestamp ?? 0}';
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  const prime = 0x100000001b3;
  final mask = BigInt.parse('ffffffffffffffff', radix: 16);
  for (final byte in utf8.encode(normalized)) {
    hash = ((hash ^ BigInt.from(byte)) * BigInt.from(prime)) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

String suggestSmsIncomeSource({
  required String message,
  required List<String> incomeSources,
}) {
  final lower = message.toLowerCase();
  const suggestions = <String, List<String>>{
    'Salary': ['salary', 'payroll', 'wages'],
    'Freelance': ['freelance', 'client payment', 'consulting'],
    'Business': ['business', 'sales settlement'],
    'Investment': ['dividend', 'interest', 'investment'],
    'Gift': ['gift'],
  };
  for (final source in incomeSources) {
    final keywords = suggestions[source];
    if (keywords != null && keywords.any(lower.contains)) return source;
  }
  return incomeSources.contains('Other')
      ? 'Other'
      : incomeSources.isNotEmpty
          ? incomeSources.first
          : '';
}

bool _isAccountLabel(String value) =>
    RegExp(r'^(?:a/c|account|your account|bank account|vpa|upi)\b',
            caseSensitive: false)
        .hasMatch(value) ||
    RegExp(r'\b(?:a/c|account|ref|txn)\b', caseSensitive: false)
        .hasMatch(value);
