import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/receipt_parser.dart';
import 'services/sms_transaction_parser.dart';

enum TransactionType { income, expense }

const overallBudgetCategory = 'Overall spending';

class MonthlyBudgetStatus {
  const MonthlyBudgetStatus({
    required this.month,
    required this.limit,
    required this.spent,
  });

  final String month;
  final double? limit;
  final double spent;

  bool get isConfigured => limit != null && limit! > 0;
  double get remaining => isConfigured ? limit! - spent : 0;
  double get percentUsed => isConfigured ? spent / limit! : 0;
  bool get isExceeded => isConfigured && spent > limit!;
  bool get isNearLimit => isConfigured && !isExceeded && percentUsed >= 0.8;
}

MonthlyBudgetStatus calculateMonthlyBudgetStatus({
  required List<TransactionRecord> transactions,
  required List<BudgetRecord> budgets,
  DateTime? referenceDate,
}) {
  final today = referenceDate ?? DateTime.now();
  final month = '${today.year.toString().padLeft(4, '0')}-'
      '${today.month.toString().padLeft(2, '0')}';
  final budget = budgets.cast<BudgetRecord?>().firstWhere(
        (item) =>
            item?.category == overallBudgetCategory && item?.month == month,
        orElse: () => null,
      );
  final spent = transactions
      .where((item) =>
          item.type == TransactionType.expense &&
          item.date.year == today.year &&
          item.date.month == today.month)
      .fold<double>(0, (total, item) => total + item.amount);
  return MonthlyBudgetStatus(
    month: month,
    limit: budget?.amount,
    spent: spent,
  );
}

DateTime? _transactionDateFromJson(String value) {
  final dateOnly =
      RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value.trim());
  if (dateOnly != null) {
    final year = int.parse(dateOnly.group(1)!);
    final month = int.parse(dateOnly.group(2)!);
    final day = int.parse(dateOnly.group(3)!);
    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return date;
  }
  return DateTime.tryParse(value)?.toLocal();
}

String _transactionDateToJson(DateTime date, String source) {
  if (source == 'sms') return date.toUtc().toIso8601String();
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

class AppUser {
  const AppUser(
      {required this.id, required this.fullName, required this.email});

  final String id;
  final String fullName;
  final String email;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      fullName: (json['fullName'] ?? 'TrackYo User').toString(),
      email: (json['email'] ?? '').toString(),
    );
  }
}

abstract class AuthTokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

class SecureAuthTokenStore implements AuthTokenStore {
  const SecureAuthTokenStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: 'trackyo_token');

  @override
  Future<void> write(String token) =>
      _storage.write(key: 'trackyo_token', value: token);

  @override
  Future<void> delete() => _storage.delete(key: 'trackyo_token');
}

class TransactionRecord {
  const TransactionRecord({
    required this.id,
    required this.type,
    required this.amount,
    required this.category,
    this.incomeSource = '',
    required this.description,
    required this.merchant,
    required this.paymentMethod,
    required this.date,
    required this.source,
    required this.receiptImage,
    this.smsFingerprint = '',
  });

  final String id;
  final TransactionType type;
  final double amount;
  final String category;
  final String incomeSource;
  final String description;
  final String merchant;
  final String paymentMethod;
  final DateTime date;
  final String source;
  final String receiptImage;
  final String smsFingerprint;

  String get classificationLabel => type == TransactionType.income
      ? (incomeSource.isNotEmpty ? incomeSource : category)
      : category;

  factory TransactionRecord.fromJson(Map<String, dynamic> json) {
    return TransactionRecord(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      type: (json['type'] ?? 'expense') == 'income'
          ? TransactionType.income
          : TransactionType.expense,
      amount: double.tryParse(json['amount']?.toString() ?? '0') ?? 0,
      category: (json['category'] ?? 'Other').toString(),
      incomeSource: (json['incomeSource'] ??
              ((json['type'] ?? 'expense') == 'income' ? json['category'] : ''))
          .toString(),
      description: (json['description'] ?? '').toString(),
      merchant: (json['merchant'] ?? '').toString(),
      paymentMethod: (json['paymentMethod'] ?? 'UPI').toString(),
      date: _transactionDateFromJson(
            (json['date'] ?? DateTime.now().toIso8601String()).toString(),
          ) ??
          DateTime.now(),
      source: (json['source'] ?? 'manual').toString(),
      receiptImage: (json['receiptImage'] ?? '').toString(),
      smsFingerprint: (json['smsFingerprint'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type == TransactionType.income ? 'income' : 'expense',
        'amount': amount,
        'category': type == TransactionType.expense ? category : '',
        'incomeSource':
            type == TransactionType.income ? classificationLabel : '',
        'description': description,
        'merchant': merchant,
        'paymentMethod': paymentMethod,
        'date': _transactionDateToJson(date, source),
        'source': source,
        'receiptImage': receiptImage,
        if (smsFingerprint.isNotEmpty) 'smsFingerprint': smsFingerprint,
      };
}

class CategoryRecord {
  const CategoryRecord({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
    this.isDefault = false,
  });

  final String id;
  final String name;
  final String icon;
  final String color;
  final bool isDefault;

  factory CategoryRecord.fromJson(Map<String, dynamic> json) {
    return CategoryRecord(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      name: (json['name'] ?? 'Other').toString(),
      icon: (json['icon'] ?? 'category').toString(),
      color: (json['color'] ?? '#3B82F6').toString(),
      isDefault: json['isDefault'] == true,
    );
  }
}

class BudgetRecord {
  const BudgetRecord({
    required this.id,
    required this.category,
    required this.amount,
    required this.month,
    this.spent = 0,
    this.remaining = 0,
    this.percentUsed = 0,
  });

  final String id;
  final String category;
  final double amount;
  final String month;
  final double spent;
  final double remaining;
  final double percentUsed;

  factory BudgetRecord.fromJson(Map<String, dynamic> json) {
    return BudgetRecord(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      category: (json['category'] ?? 'Other').toString(),
      amount: double.tryParse(json['amount']?.toString() ?? '0') ?? 0,
      month: (json['month'] ?? DateTime.now().toIso8601String().substring(0, 7))
          .toString(),
      spent: double.tryParse(json['spent']?.toString() ?? '0') ?? 0,
      remaining: double.tryParse(json['remaining']?.toString() ?? '0') ?? 0,
      percentUsed: double.tryParse(json['percentUsed']?.toString() ?? '0') ?? 0,
    );
  }
}

class AnalyticsSummary {
  const AnalyticsSummary({
    required this.totalIncome,
    required this.totalExpense,
    required this.savings,
    required this.monthlyExpense,
    this.averageDailyExpense = 0,
    this.averageMonthlyExpense = 0,
    this.highestCategory,
    this.highestExpense,
  });

  final double totalIncome;
  final double totalExpense;
  final double savings;
  final double monthlyExpense;
  final double averageDailyExpense;
  final double averageMonthlyExpense;
  final String? highestCategory;
  final Map<String, dynamic>? highestExpense;

  factory AnalyticsSummary.fromJson(Map<String, dynamic> json) {
    return AnalyticsSummary(
      totalIncome:
          double.tryParse((json['totalIncome'] ?? '0').toString()) ?? 0,
      totalExpense:
          double.tryParse((json['totalExpense'] ?? '0').toString()) ?? 0,
      savings: double.tryParse((json['savings'] ?? '0').toString()) ?? 0,
      monthlyExpense:
          double.tryParse((json['monthlyExpense'] ?? '0').toString()) ?? 0,
      averageDailyExpense:
          double.tryParse((json['averageDailyExpense'] ?? '0').toString()) ?? 0,
      averageMonthlyExpense:
          double.tryParse((json['averageMonthlyExpense'] ?? '0').toString()) ??
              0,
      highestCategory: json['highestCategory']?.toString(),
      highestExpense: json['highestExpense'] is Map<String, dynamic>
          ? json['highestExpense'] as Map<String, dynamic>
          : null,
    );
  }
}

class ApiService {
  static const String _productionApiBaseUrl = String.fromEnvironment(
    'TRACKYO_API_BASE_URL',
    defaultValue: 'https://trackyo-backend.onrender.com',
  );
  static AuthTokenStore tokenStore = const SecureAuthTokenStore();
  static VoidCallback? onUnauthorized;
  static http.Client? httpClient;

  static Future<String?> readToken(SharedPreferences prefs) async {
    final secureToken = await tokenStore.read();
    if (secureToken != null && secureToken.isNotEmpty) return secureToken;

    final legacyToken = prefs.getString('trackyo_token');
    if (legacyToken == null || legacyToken.isEmpty) return null;
    await tokenStore.write(legacyToken);
    await prefs.remove('trackyo_token');
    return legacyToken;
  }

  static String baseUrl(SharedPreferences prefs,
      {bool release = kReleaseMode}) {
    if (release) {
      final uri = Uri.tryParse(_productionApiBaseUrl);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw StateError(
          'TrackYo release builds require an HTTPS TRACKYO_API_BASE_URL.',
        );
      }
      return _productionApiBaseUrl.replaceFirst(RegExp(r'/+$'), '');
    }

    final saved = prefs.getString('api_base_url');
    if (saved != null && saved.isNotEmpty) {
      return saved.replaceFirst(RegExp(r'/+$'), '');
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://192.168.0.2:5000';
    }
    return 'https://trackyo-backend.onrender.com';
  }

  static Future<dynamic> _request(
    SharedPreferences prefs, {
    required String method,
    required String path,
    Map<String, dynamic>? body,
    String? token,
  }) async {
    final uri = Uri.parse('${baseUrl(prefs)}$path');
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = ['Bearer', token].join(' ');
    }

    http.Response response;
    try {
      final client = httpClient;
      if (method == 'GET') {
        response = await (client?.get(uri, headers: headers) ??
                http.get(uri, headers: headers))
            .timeout(
          const Duration(seconds: 45),
        );
      } else if (method == 'POST') {
        response = await (client?.post(
                  uri,
                  headers: headers,
                  body: jsonEncode(body ?? {}),
                ) ??
                http.post(uri, headers: headers, body: jsonEncode(body ?? {})))
            .timeout(const Duration(seconds: 15));
      } else if (method == 'PUT') {
        response = await (client?.put(
                  uri,
                  headers: headers,
                  body: jsonEncode(body ?? {}),
                ) ??
                http.put(uri, headers: headers, body: jsonEncode(body ?? {})))
            .timeout(const Duration(seconds: 15));
      } else if (method == 'DELETE') {
        response = await (client?.delete(uri, headers: headers) ??
                http.delete(uri, headers: headers))
            .timeout(const Duration(seconds: 15));
      } else {
        throw UnsupportedError('Unsupported HTTP method $method');
      }
    } on TimeoutException {
      throw Exception(
        'TrackYo backend is unavailable or taking too long to respond. Please try again.',
      );
    } on http.ClientException catch (error) {
      final details = error.message.toLowerCase();
      if (details.contains('failed host lookup') ||
          details.contains('network is unreachable') ||
          details.contains('no address associated') ||
          details.contains('name or service not known')) {
        throw Exception(
          'No internet connection. Check your connection and try again.',
        );
      }
      throw Exception(
        'TrackYo backend is unavailable. Please try again later.',
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return {};
      return jsonDecode(response.body);
    }

    dynamic payload;
    try {
      payload = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      payload = null;
    }
    if (response.statusCode == 401 && token != null && token.isNotEmpty) {
      await tokenStore.delete();
      onUnauthorized?.call();
    }
    if (response.statusCode >= 500) {
      throw Exception(
        'TrackYo server error (${response.statusCode}). Please try again later.',
      );
    }
    if (response.statusCode == 401 &&
        token == null &&
        path == '/api/auth/login') {
      throw Exception('Invalid email or password.');
    }
    if (payload is Map<String, dynamic>) {
      throw Exception(payload['message'] ?? 'Request failed');
    }
    throw Exception('Request failed (${response.statusCode})');
  }

  static Future<AppUser> login(SharedPreferences prefs,
      {required String email, required String password}) async {
    final result = await _request(
      prefs,
      method: 'POST',
      path: '/api/auth/login',
      body: {'email': email.trim(), 'password': password},
    );
    final token = (result['token'] ?? '').toString();
    if (token.isEmpty) {
      throw Exception('The server did not return a session token.');
    }
    await tokenStore.write(token);
    await prefs.remove('trackyo_token');
    return AppUser.fromJson(result['user'] ?? {});
  }

  static Future<AppUser> register(
    SharedPreferences prefs, {
    required String fullName,
    required String email,
    required String password,
    required String confirmPassword,
  }) async {
    final result = await _request(
      prefs,
      method: 'POST',
      path: '/api/auth/register',
      body: {
        'fullName': fullName.trim(),
        'email': email.trim(),
        'password': password,
        'confirmPassword': confirmPassword,
      },
    );
    final token = (result['token'] ?? '').toString();
    if (token.isEmpty) {
      throw Exception('The server did not return a session token.');
    }
    await tokenStore.write(token);
    await prefs.remove('trackyo_token');
    return AppUser.fromJson(result['user'] ?? {});
  }

  static Future<AppUser?> getCurrentUser(SharedPreferences prefs) async {
    final token = await readToken(prefs);
    if (token == null || token.isEmpty) return null;
    try {
      final result = await _request(prefs,
          method: 'GET', path: '/api/auth/me', token: token);
      return AppUser.fromJson(result);
    } catch (error) {
      if (error.toString().contains('Invalid or expired token') ||
          error.toString().contains('User not found')) {
        await tokenStore.delete();
        return null;
      }
      rethrow;
    }
  }

  static Future<List<TransactionRecord>> getTransactions(
    SharedPreferences prefs, {
    String? search,
    String? type,
    String? category,
    DateTime? startDate,
    DateTime? endDate,
    String sort = 'date',
    String order = 'desc',
  }) async {
    final token = await readToken(prefs) ?? '';
    final query = <String, String>{'sort': sort, 'order': order};
    if (search != null && search.trim().isNotEmpty) {
      query['search'] = search.trim();
    }
    if (type != null && type != 'all') query['type'] = type;
    if (category != null && category != 'all') query['category'] = category;
    if (startDate != null) query['startDate'] = startDate.toIso8601String();
    if (endDate != null) query['endDate'] = endDate.toIso8601String();
    final path =
        Uri(path: '/api/transactions', queryParameters: query).toString();
    final result =
        await _request(prefs, method: 'GET', path: path, token: token);
    final data = result is List ? result : const <dynamic>[];
    return data
        .map((item) => TransactionRecord.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  static Future<TransactionRecord> updateTransaction(
    SharedPreferences prefs,
    TransactionRecord transaction,
  ) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(
      prefs,
      method: 'PUT',
      path: '/api/transactions/${Uri.encodeComponent(transaction.id)}',
      token: token,
      body: transaction.toJson(),
    );
    return TransactionRecord.fromJson(result as Map<String, dynamic>);
  }

  static Future<List<CategoryRecord>> getCategories(
      SharedPreferences prefs) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(prefs,
        method: 'GET', path: '/api/categories', token: token);
    final data = result is List ? result : const <dynamic>[];
    return data
        .map((item) => CategoryRecord.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  static Future<List<String>> getIncomeSources(SharedPreferences prefs) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(prefs,
        method: 'GET', path: '/api/income-sources', token: token);
    final data = result is List ? result : const <dynamic>[];
    return data
        .map((item) => (item as Map<String, dynamic>)['name'].toString())
        .toList();
  }

  static Future<List<BudgetRecord>> getBudgets(SharedPreferences prefs) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(prefs,
        method: 'GET', path: '/api/budgets', token: token);
    final data = result is List ? result : const <dynamic>[];
    return data
        .map((item) => BudgetRecord.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  static Future<AnalyticsSummary> getSummary(SharedPreferences prefs) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(prefs,
        method: 'GET', path: '/api/analytics/summary', token: token);
    return AnalyticsSummary.fromJson(result);
  }

  static Future<List<String>> getInsights(SharedPreferences prefs) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(prefs,
        method: 'POST', path: '/api/ai/insights', token: token, body: {});
    final items = result['insights'];
    if (items is List) return items.map((item) => item.toString()).toList();
    return <String>[];
  }

  static Future<String> askAi(SharedPreferences prefs, String message) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(
      prefs,
      method: 'POST',
      path: '/api/ai/chat',
      token: token,
      body: {'message': message},
    );
    return (result['answer'] ?? 'I can help with your finances.').toString();
  }

  static Future<TransactionRecord> addTransaction(
      SharedPreferences prefs, TransactionRecord transaction) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(
      prefs,
      method: 'POST',
      path: '/api/transactions',
      token: token,
      body: transaction.toJson(),
    );
    return TransactionRecord.fromJson(result);
  }

  static Future<void> deleteTransaction(
      SharedPreferences prefs, String id) async {
    final token = await readToken(prefs) ?? '';
    await _request(prefs,
        method: 'DELETE', path: '/api/transactions/$id', token: token);
  }

  static Future<CategoryRecord> addCategory(
      SharedPreferences prefs, String name, String icon, String color) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(
      prefs,
      method: 'POST',
      path: '/api/categories',
      token: token,
      body: {'name': name, 'icon': icon, 'color': color},
    );
    return CategoryRecord.fromJson(result);
  }

  static Future<CategoryRecord> updateCategory(
      SharedPreferences prefs, CategoryRecord category) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(
      prefs,
      method: 'PUT',
      path: '/api/categories/${Uri.encodeComponent(category.id)}',
      token: token,
      body: {
        'name': category.name,
        'icon': category.icon,
        'color': category.color
      },
    );
    return CategoryRecord.fromJson(result as Map<String, dynamic>);
  }

  static Future<void> deleteCategory(SharedPreferences prefs, String id) async {
    final token = await readToken(prefs) ?? '';
    await _request(prefs,
        method: 'DELETE',
        path: '/api/categories/${Uri.encodeComponent(id)}',
        token: token);
  }

  static Future<BudgetRecord> addBudget(SharedPreferences prefs,
      String category, double amount, String month) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(
      prefs,
      method: 'POST',
      path: '/api/budgets',
      token: token,
      body: {'category': category, 'amount': amount, 'month': month},
    );
    return BudgetRecord.fromJson(result);
  }

  static Future<BudgetRecord> updateBudget(
      SharedPreferences prefs, BudgetRecord budget) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(
      prefs,
      method: 'PUT',
      path: '/api/budgets/${Uri.encodeComponent(budget.id)}',
      token: token,
      body: {
        'category': budget.category,
        'amount': budget.amount,
        'month': budget.month
      },
    );
    return BudgetRecord.fromJson(result as Map<String, dynamic>);
  }

  static Future<void> deleteBudget(SharedPreferences prefs, String id) async {
    final token = await readToken(prefs) ?? '';
    await _request(prefs,
        method: 'DELETE',
        path: '/api/budgets/${Uri.encodeComponent(id)}',
        token: token);
  }

  static Future<List<Map<String, dynamic>>> getMonthlyAnalytics(
      SharedPreferences prefs) async {
    final token = await readToken(prefs) ?? '';
    final result = await _request(prefs,
        method: 'GET', path: '/api/analytics/monthly', token: token);
    if (result is! List) return const [];
    return result.cast<Map<String, dynamic>>();
  }
}

class TrackYoApp extends StatefulWidget {
  const TrackYoApp({super.key, required this.prefs});

  final SharedPreferences prefs;

  @override
  State<TrackYoApp> createState() => _TrackYoAppState();
}

class _TrackYoAppState extends State<TrackYoApp> {
  ThemeMode _themeMode = ThemeMode.system;
  AppUser? _user;
  bool _authenticated = false;
  bool _splashDone = false;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    ApiService.onUnauthorized = () {
      if (!mounted) return;
      setState(() {
        _user = null;
        _authenticated = false;
      });
    };
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final savedTheme = widget.prefs.getString('trackyo_theme_mode');
      if (savedTheme == 'light') {
        _themeMode = ThemeMode.light;
      } else if (savedTheme == 'dark') {
        _themeMode = ThemeMode.dark;
      } else {
        _themeMode = ThemeMode.system;
      }

      final token = await ApiService.readToken(widget.prefs);
      if (token != null && token.isNotEmpty) {
        final user = await ApiService.getCurrentUser(widget.prefs);
        if (user != null) {
          _user = user;
          _authenticated = true;
        }
      }
    } catch (error) {
      _startupError = error.toString().replaceFirst('Exception: ', '');
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    setState(() => _splashDone = true);
  }

  Future<void> _handleLogin(String email, String password) async {
    final user =
        await ApiService.login(widget.prefs, email: email, password: password);
    setState(() {
      _user = user;
      _authenticated = true;
      _startupError = null;
    });
  }

  Future<void> _handleRegister(String fullName, String email, String password,
      String confirmPassword) async {
    final user = await ApiService.register(
      widget.prefs,
      fullName: fullName,
      email: email,
      password: password,
      confirmPassword: confirmPassword,
    );
    setState(() {
      _user = user;
      _authenticated = true;
      _startupError = null;
    });
  }

  Future<void> _handleLogout() async {
    await ApiService.tokenStore.delete();
    await widget.prefs.remove('trackyo_token');
    if (!mounted) return;
    setState(() {
      _user = null;
      _authenticated = false;
      _startupError = null;
    });
  }

  void _setTheme(ThemeMode mode) {
    setState(() => _themeMode = mode);
    widget.prefs.setString('trackyo_theme_mode', mode.name);
  }

  @override
  Widget build(BuildContext context) {
    ApiService.onUnauthorized = () {
      if (!mounted) return;
      setState(() {
        _user = null;
        _authenticated = false;
      });
    };
    return MaterialApp(
      title: 'TrackYo',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: TrackYoTheme.lightTheme,
      darkTheme: TrackYoTheme.darkTheme,
      home: !_splashDone
          ? const SplashScreen()
          : (_authenticated && _user != null)
              ? MainShell(
                  user: _user!,
                  prefs: widget.prefs,
                  onLogout: () => unawaited(_handleLogout()),
                  themeMode: _themeMode,
                  onThemeChanged: _setTheme,
                )
              : _startupError != null
                  ? _StartupErrorScreen(
                      message: _startupError!,
                      onRetry: () {
                        setState(() {
                          _splashDone = false;
                          _startupError = null;
                        });
                        _bootstrap();
                      },
                      onContinueToLogin: () =>
                          setState(() => _startupError = null),
                    )
                  : LoginScreen(
                      onLogin: _handleLogin,
                      onRegister: _handleRegister,
                    ),
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen({
    required this.message,
    required this.onRetry,
    required this.onContinueToLogin,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onContinueToLogin;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_outlined, size: 44),
                  const SizedBox(height: 16),
                  Text('Could not verify your session',
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: onRetry,
                    child: const Text('Try again'),
                  ),
                  TextButton(
                    onPressed: onContinueToLogin,
                    child: const Text('Continue to login'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF163638),
      body: Center(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 82,
                  height: 82,
                  decoration: BoxDecoration(
                    color: const Color(0xFF285252),
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(color: const Color(0xFF477F72)),
                  ),
                  child: const Icon(
                    Icons.account_balance_wallet_rounded,
                    size: 42,
                    color: Color(0xFF8CE0C2),
                    semanticLabel: 'TrackYo wallet logo',
                  ),
                ),
                const SizedBox(height: 19),
                const Text(
                  'TrackYo',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -.5,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Track your money. Own your future.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFFB1C9C3),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 26),
                const SizedBox(
                  width: 23,
                  height: 23,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Color(0xFF8CE0C2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen(
      {super.key, required this.onLogin, required this.onRegister});

  final Future<void> Function(String email, String password) onLogin;
  final Future<void> Function(String fullName, String email, String password,
      String confirmPassword) onRegister;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _loginKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSubmitting = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submitLogin() async {
    if (!_loginKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);
    try {
      await widget.onLogin(_emailController.text, _passwordController.text);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_authErrorMessage(error))),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _loginKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 30),
                    Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Icon(Icons.account_balance_wallet_rounded,
                          color: Theme.of(context).colorScheme.primary,
                          size: 36),
                    ),
                    const SizedBox(height: 24),
                    Text('Welcome back',
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text('Track your money. Own your future.',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                    const SizedBox(height: 28),
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Email is required';
                        }
                        if (!_isValidEmail(value)) return 'Enter a valid email';
                        return null;
                      },
                      decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.email_outlined),
                          border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: !_showPassword,
                      validator: (value) {
                        if (value == null || value.length < 8) {
                          return 'Password must be at least 8 characters';
                        }
                        if (utf8.encode(value).length > 72) {
                          return 'Password must be no longer than 72 bytes';
                        }
                        return null;
                      },
                      decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            tooltip: _showPassword
                                ? 'Hide password'
                                : 'Show password',
                            onPressed: _isSubmitting
                                ? null
                                : () => setState(
                                    () => _showPassword = !_showPassword),
                            icon: Icon(_showPassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined),
                          )),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _isSubmitting ? null : _submitLogin,
                        icon: _isSubmitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.login_rounded),
                        label: Text(_isSubmitting ? 'Logging in...' : 'Login'),
                        style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16))),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _isSubmitting
                            ? null
                            : () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => RegisterScreen(
                                      onRegister: widget.onRegister,
                                    ),
                                  ),
                                ),
                        icon: const Icon(Icons.person_add_alt_1_outlined),
                        label: const Text('Create account'),
                        style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16))),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, required this.onRegister});

  final Future<void> Function(String fullName, String email, String password,
      String confirmPassword) onRegister;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _isSubmitting = false;
  bool _showPassword = false;
  bool _showConfirmPassword = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);
    try {
      await widget.onRegister(
        _nameController.text,
        _emailController.text,
        _passwordController.text,
        _confirmController.text,
      );
      if (mounted) Navigator.of(context).maybePop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_authErrorMessage(error))),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _nameController,
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? 'Full name required'
                      : null,
                  decoration: const InputDecoration(
                      labelText: 'Full name',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Email required';
                    }
                    if (!_isValidEmail(value)) return 'Enter a valid email';
                    return null;
                  },
                  decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email_outlined),
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordController,
                  obscureText: !_showPassword,
                  validator: (value) {
                    if (value == null || value.length < 8) {
                      return 'Password must be at least 8 characters';
                    }
                    if (utf8.encode(value).length > 72) {
                      return 'Password must be no longer than 72 bytes';
                    }
                    return null;
                  },
                  decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip:
                            _showPassword ? 'Hide password' : 'Show password',
                        onPressed: _isSubmitting
                            ? null
                            : () =>
                                setState(() => _showPassword = !_showPassword),
                        icon: Icon(_showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                      )),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _confirmController,
                  obscureText: !_showConfirmPassword,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Confirm password';
                    }
                    if (value != _passwordController.text) {
                      return 'Passwords do not match';
                    }
                    return null;
                  },
                  decoration: InputDecoration(
                      labelText: 'Confirm password',
                      prefixIcon: const Icon(Icons.lock_reset),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _showConfirmPassword
                            ? 'Hide password'
                            : 'Show password',
                        onPressed: _isSubmitting
                            ? null
                            : () => setState(() =>
                                _showConfirmPassword = !_showConfirmPassword),
                        icon: Icon(_showConfirmPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                      )),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isSubmitting ? null : _submit,
                    icon: _isSubmitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.check_circle_outline),
                    label: Text(
                        _isSubmitting ? 'Creating account...' : 'Register'),
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16))),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _isSubmitting
                      ? null
                      : () => Navigator.of(context).maybePop(),
                  child: const Text('Already have an account? Log in'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.user,
    required this.prefs,
    required this.onLogout,
    required this.themeMode,
    required this.onThemeChanged,
  });

  final AppUser user;
  final SharedPreferences prefs;
  final VoidCallback onLogout;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;
  TransactionType _addType = TransactionType.expense;
  bool _loading = true;
  String? _error;
  List<TransactionRecord> _transactions = const [];
  List<CategoryRecord> _categories = const [];
  List<String> _incomeSources = const [];
  List<BudgetRecord> _budgets = const [];
  List<String> _insights = const [];
  List<Map<String, dynamic>> _monthlyAnalytics = const [];
  String? _pendingQuickAction;
  AnalyticsSummary _summary = const AnalyticsSummary(
      totalIncome: 0, totalExpense: 0, savings: 0, monthlyExpense: 0);
  String _searchQuery = '';
  String? _filterCategory;
  String _filterType = 'all';
  DateTimeRange? _filterDateRange;
  String _sortMode = 'newest';
  List<TransactionRecord>? _remoteFilteredTransactions;
  Timer? _filterDebounce;
  int _filterRequestId = 0;

  void _launchQuickAction(String action) {
    setState(() {
      _addType = TransactionType.expense;
      _pendingQuickAction = action;
      _selectedIndex = 2;
    });
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        ApiService.getTransactions(widget.prefs),
        ApiService.getCategories(widget.prefs),
        ApiService.getIncomeSources(widget.prefs),
        ApiService.getBudgets(widget.prefs),
        ApiService.getSummary(widget.prefs),
        ApiService.getInsights(widget.prefs),
        ApiService.getMonthlyAnalytics(widget.prefs),
      ]);
      if (!mounted) return;
      setState(() {
        _transactions = results[0] as List<TransactionRecord>;
        _categories = results[1] as List<CategoryRecord>;
        _incomeSources = results[2] as List<String>;
        _budgets = results[3] as List<BudgetRecord>;
        _summary = results[4] as AnalyticsSummary;
        _insights = results[5] as List<String>;
        _monthlyAnalytics = results[6] as List<Map<String, dynamic>>;
        _remoteFilteredTransactions = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    super.dispose();
  }

  void _scheduleServerFilter() {
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 250), () async {
      final requestId = ++_filterRequestId;
      try {
        final isAmount = _sortMode.startsWith('amount_');
        final results = await ApiService.getTransactions(
          widget.prefs,
          search: _searchQuery,
          type: _filterType,
          category: _filterCategory,
          startDate: _filterDateRange?.start,
          endDate: _filterDateRange == null
              ? null
              : DateTime(
                  _filterDateRange!.end.year,
                  _filterDateRange!.end.month,
                  _filterDateRange!.end.day,
                  23,
                  59,
                  59,
                ),
          sort: isAmount ? 'amount' : 'date',
          order: _sortMode == 'oldest' || _sortMode == 'amount_low'
              ? 'asc'
              : 'desc',
        );
        if (!mounted || requestId != _filterRequestId) return;
        setState(() => _remoteFilteredTransactions = results);
      } catch (error) {
        if (!mounted || requestId != _filterRequestId) return;
        setState(() => _remoteFilteredTransactions = null);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Server search failed: $error')));
      }
    });
  }

  void _setSearchQuery(String value) {
    setState(() {
      _searchQuery = value;
      _remoteFilteredTransactions = null;
    });
    _scheduleServerFilter();
  }

  void _setCategoryFilter(String? value) {
    setState(() {
      _filterCategory = value;
      _remoteFilteredTransactions = null;
    });
    _scheduleServerFilter();
  }

  void _setTypeFilter(String value) {
    setState(() {
      _filterType = value;
      _remoteFilteredTransactions = null;
    });
    _scheduleServerFilter();
  }

  void _setDateFilter(DateTimeRange? value) {
    setState(() {
      _filterDateRange = value;
      _remoteFilteredTransactions = null;
    });
    _scheduleServerFilter();
  }

  void _setSortFilter(String value) {
    setState(() {
      _sortMode = value;
      _remoteFilteredTransactions = null;
    });
    _scheduleServerFilter();
  }

  Future<void> _deleteTransaction(String id) async {
    try {
      await ApiService.deleteTransaction(widget.prefs, id);
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Transaction deleted')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _editTransaction(TransactionRecord original) async {
    final amountController =
        TextEditingController(text: original.amount.toStringAsFixed(2));
    final merchantController = TextEditingController(text: original.merchant);
    final descriptionController =
        TextEditingController(text: original.description);
    var classification = original.classificationLabel;
    final options = original.type == TransactionType.expense
        ? _categories.map((item) => item.name)
        : _incomeSources;
    final formKey = GlobalKey<FormState>();
    final save = await showDialog<TransactionRecord>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Edit ${original.type.name}'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: amountController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    validator: (value) {
                      final amount = double.tryParse(value ?? '');
                      return amount == null || amount <= 0
                          ? 'Enter a valid amount'
                          : null;
                    },
                    decoration: const InputDecoration(labelText: 'Amount'),
                  ),
                  DropdownButtonFormField<String>(
                    value: classification,
                    items: {classification, ...options}
                        .map((name) =>
                            DropdownMenuItem(value: name, child: Text(name)))
                        .toList(),
                    onChanged: (value) => setDialogState(
                        () => classification = value ?? classification),
                    decoration: InputDecoration(
                      labelText: original.type == TransactionType.expense
                          ? 'Category'
                          : 'Income source',
                    ),
                  ),
                  if (original.type == TransactionType.expense)
                    TextFormField(
                        controller: merchantController,
                        decoration:
                            const InputDecoration(labelText: 'Merchant')),
                  TextFormField(
                      controller: descriptionController,
                      decoration:
                          const InputDecoration(labelText: 'Description')),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (!(formKey.currentState?.validate() ?? false)) return;
                Navigator.pop(
                  dialogContext,
                  TransactionRecord(
                    id: original.id,
                    type: original.type,
                    amount: double.parse(amountController.text),
                    category: original.type == TransactionType.expense
                        ? classification
                        : '',
                    incomeSource: original.type == TransactionType.income
                        ? classification
                        : '',
                    description: descriptionController.text.trim(),
                    merchant: merchantController.text.trim(),
                    paymentMethod: original.paymentMethod,
                    date: original.date,
                    source: original.source,
                    receiptImage: original.receiptImage,
                    smsFingerprint: original.smsFingerprint,
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    amountController.dispose();
    merchantController.dispose();
    descriptionController.dispose();
    if (save == null) return;
    try {
      await ApiService.updateTransaction(widget.prefs, save);
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Transaction updated')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _saveTransaction({
    required TransactionType type,
    required double amount,
    required String category,
    String incomeSource = '',
    required String description,
    required String merchant,
    required String paymentMethod,
    required String source,
    DateTime? date,
    String receiptImage = '',
    String smsFingerprint = '',
  }) async {
    await ApiService.addTransaction(
      widget.prefs,
      TransactionRecord(
        id: '',
        type: type,
        amount: amount,
        category: category,
        incomeSource: incomeSource,
        description: description,
        merchant: merchant,
        paymentMethod: paymentMethod,
        date: date ?? DateTime.now(),
        source: source,
        receiptImage: receiptImage,
        smsFingerprint: smsFingerprint,
      ),
    );
    await _loadData();
  }

  List<TransactionRecord> get filteredTransactions {
    if (_remoteFilteredTransactions != null) {
      return _remoteFilteredTransactions!;
    }
    final query = _searchQuery.trim().toLowerCase();
    return _transactions.where((t) {
      final matchesQuery = query.isEmpty ||
          t.category.toLowerCase().contains(query) ||
          t.incomeSource.toLowerCase().contains(query) ||
          t.description.toLowerCase().contains(query) ||
          t.merchant.toLowerCase().contains(query);
      final matchesCategory = _filterCategory == null ||
          _filterCategory == 'all' ||
          (t.type == TransactionType.expense && t.category == _filterCategory);
      final matchesType = _filterType == 'all' ||
          (_filterType == 'income' && t.type == TransactionType.income) ||
          (_filterType == 'expense' && t.type == TransactionType.expense);
      final matchesDate = _filterDateRange == null ||
          (!t.date.isBefore(_filterDateRange!.start) &&
              !t.date.isAfter(DateTime(
                _filterDateRange!.end.year,
                _filterDateRange!.end.month,
                _filterDateRange!.end.day,
                23,
                59,
                59,
              )));
      return matchesQuery && matchesCategory && matchesType && matchesDate;
    }).toList()
      ..sort((a, b) {
        switch (_sortMode) {
          case 'oldest':
            return a.date.compareTo(b.date);
          case 'amount_low':
            return a.amount.compareTo(b.amount);
          case 'amount_high':
            return b.amount.compareTo(a.amount);
          default:
            return b.date.compareTo(a.date);
        }
      });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardView(
        user: widget.user,
        transactions: _transactions,
        summary: _summary,
        insights: _insights,
        budgets: _budgets,
        monthlyData: _monthlyAnalytics,
        onRefresh: _loadData,
        onAddTransaction: (type) => setState(() {
          _addType = type;
          _selectedIndex = 2;
        }),
        onScanReceipt: () => _launchQuickAction('receipt'),
        onScanSms: () => _launchQuickAction('sms'),
        onOpenTransactions: () => setState(() => _selectedIndex = 1),
        onOpenAi: () {
          if (widget.prefs.getBool('trackyo_ai_enabled') == false) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('AI assistant is turned off in Profile settings.'),
            ));
            return;
          }
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AiChatScreen(prefs: widget.prefs),
            ),
          );
        },
        onManageBudget: () async {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => BudgetManagementScreen(prefs: widget.prefs),
            ),
          );
          if (mounted) await _loadData();
        },
      ),
      TransactionsView(
        transactions: filteredTransactions,
        categories: _categories,
        incomeSources: _incomeSources,
        onDelete: _deleteTransaction,
        onEdit: _editTransaction,
        onSearchChanged: _setSearchQuery,
        onCategoryChanged: _setCategoryFilter,
        onTypeChanged: _setTypeFilter,
        dateRange: _filterDateRange,
        onDateRangeChanged: _setDateFilter,
        sortMode: _sortMode,
        onSortChanged: _setSortFilter,
        hasTransactions: _transactions.isNotEmpty,
        onAddTransaction: () => setState(() {
          _addType = TransactionType.expense;
          _selectedIndex = 2;
        }),
      ),
      AddTransactionView(
        categories: _categories,
        incomeSources: _incomeSources,
        existingSmsFingerprints: _transactions
            .where((item) =>
                item.source == 'sms' && item.smsFingerprint.isNotEmpty)
            .map((item) => item.smsFingerprint)
            .toSet(),
        onSaved: _saveTransaction,
        prefs: widget.prefs,
        onCategoriesChanged: _loadData,
        initialType: _addType,
        quickAction: _pendingQuickAction,
        onQuickActionHandled: () {
          if (_pendingQuickAction != null && mounted) {
            setState(() => _pendingQuickAction = null);
          }
        },
      ),
      AnalyticsView(
        transactions: _transactions,
      ),
      ProfileView(
        user: widget.user,
        prefs: widget.prefs,
        onLogout: widget.onLogout,
        themeMode: widget.themeMode,
        onThemeChanged: widget.onThemeChanged,
        onDataChanged: _loadData,
        transactions: _transactions,
        categories: _categories,
      ),
    ];

    return Scaffold(
      body: _loading
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.account_balance_wallet_rounded,
                      size: 32, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 12),
                  const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.2)),
                  const SizedBox(height: 10),
                  Text('Loading your finances',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            )
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            size: 40, color: Colors.red),
                        const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(
                            onPressed: _loadData, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : IndexedStack(index: _selectedIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (value) =>
            setState(() => _selectedIndex = value),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long_rounded),
              label: 'Transactions'),
          NavigationDestination(
              icon: _AddNavigationIcon(selected: false),
              selectedIcon: _AddNavigationIcon(selected: true),
              label: 'Add'),
          NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights_rounded),
              label: 'Analytics'),
          NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Profile'),
        ],
      ),
    );
  }
}

class _AddNavigationIcon extends StatelessWidget {
  const _AddNavigationIcon({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 38,
      height: 30,
      decoration: BoxDecoration(
        color: selected ? colors.primary : colors.primaryContainer,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(
        Icons.add_rounded,
        size: 22,
        color: selected ? colors.onPrimary : colors.onPrimaryContainer,
      ),
    );
  }
}

class _MonthlyBudgetCard extends StatelessWidget {
  const _MonthlyBudgetCard({
    required this.status,
    required this.onManage,
  });

  final MonthlyBudgetStatus status;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final exceeded = status.isExceeded;
    final warning = status.isNearLimit;
    final accent = exceeded
        ? const Color(0xFFE77872)
        : warning
            ? const Color(0xFFE5A13E)
            : const Color(0xFF38B89A);
    return _DashboardPanel(
      title: 'Monthly budget',
      icon: Icons.savings_outlined,
      action: TextButton(
        onPressed: onManage,
        child: Text(status.isConfigured ? 'Edit / reset' : 'Set budget'),
      ),
      child: status.isConfigured
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    _HighlightValue(
                      label: 'Budget',
                      value: formatCurrency(status.limit!),
                    ),
                    _HighlightValue(
                      label: 'Spent',
                      value: formatCurrency(status.spent),
                    ),
                    _HighlightValue(
                      label: exceeded ? 'Over budget' : 'Remaining',
                      value: formatCurrency(status.remaining.abs()),
                    ),
                    _HighlightValue(
                      label: 'Used',
                      value:
                          '${(status.percentUsed * 100).toStringAsFixed(1)}%',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: status.percentUsed.clamp(0.0, 1.0),
                    minHeight: 10,
                    color: accent,
                    backgroundColor: colors.surfaceVariant,
                  ),
                ),
                if (exceeded || warning) ...[
                  const SizedBox(height: 8),
                  Text(
                    exceeded
                        ? 'Budget exceeded by ${formatCurrency(status.remaining.abs())}.'
                        : 'You are close to your monthly budget limit.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Text(
                    'Set a monthly spending limit to track expenses and see what remains.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(
                  onPressed: onManage,
                  child: const Text('Set budget'),
                ),
              ],
            ),
    );
  }
}

class DashboardView extends StatelessWidget {
  const DashboardView({
    super.key,
    required this.user,
    required this.transactions,
    required this.summary,
    required this.insights,
    required this.budgets,
    required this.monthlyData,
    required this.onRefresh,
    required this.onAddTransaction,
    required this.onScanReceipt,
    required this.onScanSms,
    required this.onOpenTransactions,
    required this.onOpenAi,
    required this.onManageBudget,
  });

  final AppUser user;
  final List<TransactionRecord> transactions;
  final AnalyticsSummary summary;
  final List<String> insights;
  final List<BudgetRecord> budgets;
  final List<Map<String, dynamic>> monthlyData;
  final Future<void> Function() onRefresh;
  final ValueChanged<TransactionType> onAddTransaction;
  final VoidCallback onScanReceipt;
  final VoidCallback onScanSms;
  final VoidCallback onOpenTransactions;
  final VoidCallback onOpenAi;
  final VoidCallback onManageBudget;

  double get totalBalance => summary.totalIncome - summary.totalExpense;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final thisMonth = transactions.where(
        (item) => item.date.year == now.year && item.date.month == now.month);
    final currentMonthExpenses = thisMonth
        .where((item) => item.type == TransactionType.expense)
        .toList();
    final currentMonthIncome = thisMonth
        .where((item) => item.type == TransactionType.income)
        .fold<double>(0, (total, item) => total + item.amount);
    final currentMonthSpend = currentMonthExpenses.fold<double>(
        0, (total, item) => total + item.amount);
    final previousMonth = DateTime(now.year, now.month - 1);
    final previousMonthExpenses = transactions.where((item) =>
        item.type == TransactionType.expense &&
        item.date.year == previousMonth.year &&
        item.date.month == previousMonth.month);
    final previousMonthSpend = previousMonthExpenses.fold<double>(
        0, (total, item) => total + item.amount);
    final hasPreviousMonthData = previousMonthExpenses.isNotEmpty;
    final spendingDifference = hasPreviousMonthData && previousMonthSpend != 0
        ? ((currentMonthSpend - previousMonthSpend) / previousMonthSpend * 100)
        : null;
    final categorySpend = <String, double>{};
    for (final transaction in currentMonthExpenses) {
      categorySpend[transaction.category] =
          (categorySpend[transaction.category] ?? 0) + transaction.amount;
    }
    final topSpending = categorySpend.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final recent = transactions.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final hasTransactions = transactions.isNotEmpty;
    final budgetStatus = calculateMonthlyBudgetStatus(
      transactions: transactions,
      budgets: budgets,
    );
    final monthLabel = _monthName(now.month);
    final insight = _dashboardInsight(
      transactions: transactions,
      categorySpend: topSpending,
      currentMonthSpend: currentMonthSpend,
      previousMonthSpend: previousMonthSpend,
      hasPreviousMonthData: hasPreviousMonthData,
      budgetStatus: budgetStatus,
      allTimeIncome: summary.totalIncome,
      allTimeExpense: summary.totalExpense,
      backendInsights: insights,
    );
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Good ${_timeGreeting()}, ${user.fullName.trim().split(RegExp(r'\s+')).first}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text('$monthLabel ${now.year}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w500)),
          ],
        ),
        actions: [
          IconButton(
              tooltip: 'Refresh',
              onPressed: () async => onRefresh(),
              icon: const Icon(Icons.refresh_rounded)),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          final width =
              math.max(0.0, math.min(constraints.maxWidth - 36.0, 1180.0));
          final twoColumns = width >= 760;
          final panelWidth = twoColumns ? (width - 14) / 2 : width;
          return SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 36),
            child: Center(
              child: SizedBox(
                width: width,
                child: Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    if (hasTransactions)
                      SizedBox(
                        width: width,
                        child: _BalanceHero(
                          balance: totalBalance,
                          income: summary.totalIncome,
                          expenses: summary.totalExpense,
                          savings: totalBalance,
                          onAddExpense: () =>
                              onAddTransaction(TransactionType.expense),
                          onAddIncome: () =>
                              onAddTransaction(TransactionType.income),
                        ),
                      )
                    else
                      SizedBox(
                        width: width,
                        child: _DashboardEmpty(
                          onAddExpense: () =>
                              onAddTransaction(TransactionType.expense),
                          onAddIncome: () =>
                              onAddTransaction(TransactionType.income),
                        ),
                      ),
                    SizedBox(
                      width: width,
                      child: _QuickActions(
                        onAddExpense: () =>
                            onAddTransaction(TransactionType.expense),
                        onAddIncome: () =>
                            onAddTransaction(TransactionType.income),
                        onScanReceipt: onScanReceipt,
                        onScanSms: onScanSms,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _MonthlyBudgetCard(
                        status: budgetStatus,
                        onManage: onManageBudget,
                      ),
                    ),
                    SizedBox(
                      width: panelWidth,
                      child: _DashboardPanel(
                        title: 'AI Smart Insight',
                        icon: Icons.auto_awesome_rounded,
                        action: TextButton(
                          onPressed: onOpenAi,
                          child: const Text('Ask AI'),
                        ),
                        child: Text(
                          insight,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: panelWidth,
                      child: _DashboardPanel(
                        title: 'Top categories · $monthLabel',
                        icon: Icons.donut_small_rounded,
                        child: topSpending.isEmpty
                            ? const _InlineEmpty(
                                message: 'No expenses recorded this month yet.')
                            : Column(
                                children: topSpending.take(3).map((entry) {
                                  return _CategorySpendRow(
                                    name: entry.key,
                                    amount: entry.value,
                                    fraction: currentMonthSpend <= 0
                                        ? 0
                                        : entry.value / currentMonthSpend,
                                  );
                                }).toList(),
                              ),
                      ),
                    ),
                    SizedBox(
                      width: panelWidth,
                      child: _DashboardPanel(
                        title: 'Monthly trend',
                        icon: Icons.bar_chart_rounded,
                        child: monthlyData.isEmpty
                            ? const _InlineEmpty(
                                message:
                                    'Monthly trend will appear as you track spending.')
                            : SizedBox(
                                height: 142,
                                child: CustomPaint(
                                  painter: _MonthlyBarPainter(monthlyData),
                                  child: const SizedBox.expand(),
                                ),
                              ),
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _DashboardPanel(
                        title: 'Monthly spending',
                        icon: Icons.calendar_month_outlined,
                        child: _MonthlySpendingSummary(
                          monthLabel: monthLabel,
                          currentSpend: currentMonthSpend,
                          previousSpend: previousMonthSpend,
                          hasPreviousMonthData: hasPreviousMonthData,
                          differencePercent: spendingDifference,
                          currentMonthIncome: currentMonthIncome,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _DashboardPanel(
                        title: 'Recent transactions',
                        icon: Icons.receipt_long_outlined,
                        action: TextButton(
                          onPressed: onOpenTransactions,
                          child: const Text('View all'),
                        ),
                        child: recent.isEmpty
                            ? _ActionEmpty(
                                message:
                                    'Your recent activity will appear here.',
                                actionLabel: 'Add expense',
                                onPressed: () => onAddTransaction(
                                  TransactionType.expense,
                                ),
                              )
                            : Column(
                                children: recent
                                    .take(5)
                                    .map((transaction) => TransactionTile(
                                          transaction: transaction,
                                        ))
                                    .toList(),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _DashboardEmpty extends StatelessWidget {
  const _DashboardEmpty({
    required this.onAddExpense,
    required this.onAddIncome,
  });

  final VoidCallback onAddExpense;
  final VoidCallback onAddIncome;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _DashboardPanel(
      title: 'Your finances at a glance',
      icon: Icons.account_balance_wallet_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Start building a clearer picture of your money.',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.onSurface,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Add your first income or expense to see balances, spending trends, and personalized insights here.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: onAddExpense,
                icon: const Icon(Icons.remove_rounded),
                label: const Text('Add expense'),
              ),
              OutlinedButton.icon(
                onPressed: onAddIncome,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add income'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.onAddExpense,
    required this.onAddIncome,
    required this.onScanReceipt,
    required this.onScanSms,
  });

  final VoidCallback onAddExpense;
  final VoidCallback onAddIncome;
  final VoidCallback onScanReceipt;
  final VoidCallback onScanSms;

  @override
  Widget build(BuildContext context) {
    return _DashboardPanel(
      title: 'Quick actions',
      icon: Icons.bolt_rounded,
      child: LayoutBuilder(builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 10) / 2;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: itemWidth,
              child: FilledButton.tonalIcon(
                onPressed: onAddExpense,
                icon: const Icon(Icons.remove_circle_outline_rounded),
                label: const Text('Add expense'),
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: FilledButton.tonalIcon(
                onPressed: onAddIncome,
                icon: const Icon(Icons.add_circle_outline_rounded),
                label: const Text('Add income'),
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: OutlinedButton.icon(
                onPressed: onScanReceipt,
                icon: const Icon(Icons.document_scanner_outlined),
                label: const Text('Scan receipt'),
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: OutlinedButton.icon(
                onPressed: onScanSms,
                icon: const Icon(Icons.sms_outlined),
                label: const Text('Scan SMS'),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _MonthlySpendingSummary extends StatelessWidget {
  const _MonthlySpendingSummary({
    required this.monthLabel,
    required this.currentSpend,
    required this.previousSpend,
    required this.hasPreviousMonthData,
    required this.differencePercent,
    required this.currentMonthIncome,
  });

  final String monthLabel;
  final double currentSpend;
  final double previousSpend;
  final bool hasPreviousMonthData;
  final double? differencePercent;
  final double currentMonthIncome;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final previousLabel = _monthName(
        DateTime(DateTime.now().year, DateTime.now().month - 1).month);
    final diff = differencePercent;
    final diffColor = diff == null
        ? colors.onSurfaceVariant
        : diff > 0
            ? const Color(0xFFE77872)
            : const Color(0xFF38B89A);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 26,
          runSpacing: 12,
          children: [
            if (currentSpend > 0)
              _HighlightValue(
                label: '$monthLabel spending',
                value: formatCurrency(currentSpend),
              ),
            if (hasPreviousMonthData)
              _HighlightValue(
                label: '$previousLabel spending',
                value: formatCurrency(previousSpend),
              ),
            if (currentMonthIncome > 0)
              _HighlightValue(
                label: '$monthLabel income',
                value: formatCurrency(currentMonthIncome),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (currentSpend <= 0 && !hasPreviousMonthData)
          const _InlineEmpty(message: 'No expenses recorded this month yet.')
        else if (!hasPreviousMonthData)
          const _InlineEmpty(
              message: 'Previous-month spending will appear when available.')
        else if (diff == null)
          const _InlineEmpty(
              message: 'No previous-month spending to compare against.')
        else
          Row(
            children: [
              Icon(
                diff > 0
                    ? Icons.trending_up_rounded
                    : diff < 0
                        ? Icons.trending_down_rounded
                        : Icons.trending_flat_rounded,
                size: 19,
                color: diffColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  diff == 0
                      ? 'Spending is unchanged from last month.'
                      : 'Spent ${diff.abs().toStringAsFixed(1)}% ${diff > 0 ? 'more' : 'less'} than last month.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: diffColor,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

String _timeGreeting() {
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

String _dashboardInsight({
  required List<TransactionRecord> transactions,
  required List<MapEntry<String, double>> categorySpend,
  required double currentMonthSpend,
  required double previousMonthSpend,
  required bool hasPreviousMonthData,
  required MonthlyBudgetStatus budgetStatus,
  required double allTimeIncome,
  required double allTimeExpense,
  required List<String> backendInsights,
}) {
  if (transactions.isEmpty) {
    return 'Add more transactions to get personalized insights.';
  }
  final insights = <String>[];
  if (categorySpend.isNotEmpty) {
    insights.add(
        '${categorySpend.first.key} is your highest-spending category this month at ${formatCurrency(categorySpend.first.value)}.');
  }
  if (budgetStatus.isExceeded) {
    insights.add(
        'You are over your monthly budget by ${formatCurrency(budgetStatus.remaining.abs())}.');
  } else if (budgetStatus.isNearLimit) {
    insights.add(
        'You have used ${(budgetStatus.percentUsed * 100).round()}% of your monthly budget.');
  }
  if (hasPreviousMonthData && previousMonthSpend > 0) {
    final difference =
        (currentMonthSpend - previousMonthSpend) / previousMonthSpend * 100;
    if (difference.abs() >= 1) {
      insights.add(
          'Monthly spending is ${difference > 0 ? 'up' : 'down'} ${difference.abs().toStringAsFixed(0)}% compared with last month.');
    }
  }
  if (insights.isEmpty && allTimeIncome > 0) {
    insights.add(
        'Income is ${formatCurrency(allTimeIncome)} and expenses are ${formatCurrency(allTimeExpense)} across your saved transactions.');
  }
  if (insights.isEmpty && backendInsights.isNotEmpty) {
    insights.add(backendInsights.first);
  }
  return insights.isEmpty
      ? 'Add more transactions to get personalized insights.'
      : insights.take(2).join(' ');
}

class _BalanceHero extends StatelessWidget {
  const _BalanceHero({
    required this.balance,
    required this.income,
    required this.expenses,
    required this.savings,
    required this.onAddExpense,
    required this.onAddIncome,
  });

  final double balance;
  final double income;
  final double expenses;
  final double savings;
  final VoidCallback onAddExpense;
  final VoidCallback onAddIncome;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF163638),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF285252)),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 650;
        final summary = Wrap(
          spacing: 26,
          runSpacing: 12,
          children: [
            _HeroValue(label: 'Income', value: income, positive: true),
            _HeroValue(label: 'Expenses', value: expenses, positive: false),
            _HeroValue(
                label: 'Savings / net balance', value: savings, positive: true),
          ],
        );
        final actions = Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: onAddExpense,
              icon: const Icon(Icons.remove_rounded, size: 18),
              label: const Text('Add expense'),
              style: FilledButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: const Color(0xFFE77872),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
            OutlinedButton.icon(
              onPressed: onAddIncome,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add income'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF8CE0C2),
                side: const BorderSide(color: Color(0xFF477F72)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ],
        );
        final balanceContent = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('TOTAL BALANCE',
                style: TextStyle(
                    color: Color(0xFFB1C9C3),
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatCurrency(balance),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1),
              ),
            ),
            const SizedBox(height: 20),
            summary,
          ],
        );
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              balanceContent,
              const SizedBox(height: 20),
              actions,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: balanceContent),
            const SizedBox(width: 20),
            Flexible(child: actions),
          ],
        );
      }),
    );
  }
}

class _HeroValue extends StatelessWidget {
  const _HeroValue({
    required this.label,
    required this.value,
    required this.positive,
  });

  final String label;
  final double value;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: Color(0xFFB1C9C3), fontSize: 12)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            formatCurrency(value),
            maxLines: 1,
            style: TextStyle(
              color:
                  positive ? const Color(0xFF8CE0C2) : const Color(0xFFFFA39B),
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _DashboardPanel extends StatelessWidget {
  const _DashboardPanel({
    required this.title,
    required this.icon,
    required this.child,
    this.action,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.outlineVariant.withOpacity(.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 19, color: colors.primary),
              const SizedBox(width: 9),
              Expanded(
                child: Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (action != null) action!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(message,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant));
  }
}

class _ActionEmpty extends StatelessWidget {
  const _ActionEmpty({
    required this.message,
    required this.actionLabel,
    required this.onPressed,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _InlineEmpty(message: message)),
        TextButton(onPressed: onPressed, child: Text(actionLabel)),
      ],
    );
  }
}

class _CategorySpendRow extends StatelessWidget {
  const _CategorySpendRow({
    required this.name,
    required this.amount,
    required this.fraction,
  });

  final String name;
  final double amount;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              Text(
                '${(fraction * 100).round()}%  ${formatCurrency(amount)}',
                maxLines: 1,
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: fraction.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: colors.surfaceVariant,
              color: colors.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class TransactionsView extends StatefulWidget {
  const TransactionsView({
    super.key,
    required this.transactions,
    required this.categories,
    required this.incomeSources,
    required this.onDelete,
    required this.onEdit,
    required this.onSearchChanged,
    required this.onCategoryChanged,
    required this.onTypeChanged,
    required this.dateRange,
    required this.onDateRangeChanged,
    required this.sortMode,
    required this.onSortChanged,
    required this.hasTransactions,
    required this.onAddTransaction,
  });

  final List<TransactionRecord> transactions;
  final List<CategoryRecord> categories;
  final List<String> incomeSources;
  final Future<void> Function(String id) onDelete;
  final Future<void> Function(TransactionRecord transaction) onEdit;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String?> onCategoryChanged;
  final ValueChanged<String> onTypeChanged;
  final DateTimeRange? dateRange;
  final ValueChanged<DateTimeRange?> onDateRangeChanged;
  final String sortMode;
  final ValueChanged<String> onSortChanged;
  final bool hasTransactions;
  final VoidCallback onAddTransaction;

  @override
  State<TransactionsView> createState() => _TransactionsViewState();
}

class _TransactionsViewState extends State<TransactionsView> {
  String? _category = 'all';
  String _type = 'all';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Transactions'),
            Text('Your money, all in one place',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    onChanged: widget.onSearchChanged,
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Search transactions',
                        border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(builder: (context, constraints) {
                    final stacked = constraints.maxWidth < 520;
                    final fieldWidth = stacked
                        ? constraints.maxWidth
                        : (constraints.maxWidth - 10) / 2;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        SizedBox(
                          width: fieldWidth,
                          child: DropdownButtonFormField<String>(
                            value: _category,
                            items: [
                              const DropdownMenuItem(
                                  value: 'all', child: Text('All categories')),
                              ...widget.categories.map((category) =>
                                  DropdownMenuItem(
                                      value: category.name,
                                      child: Text(category.name)))
                            ],
                            onChanged: (value) {
                              setState(() => _category = value ?? 'all');
                              widget.onCategoryChanged(value ?? 'all');
                            },
                            decoration: const InputDecoration(
                                labelText: 'Category',
                                prefixIcon: Icon(Icons.sell_outlined)),
                          ),
                        ),
                        SizedBox(
                          width: fieldWidth,
                          child: DropdownButtonFormField<String>(
                            value: _type,
                            items: const [
                              DropdownMenuItem(
                                  value: 'all', child: Text('All')),
                              DropdownMenuItem(
                                  value: 'income', child: Text('Income')),
                              DropdownMenuItem(
                                  value: 'expense', child: Text('Expense')),
                            ],
                            onChanged: (value) {
                              setState(() => _type = value ?? 'all');
                              widget.onTypeChanged(value ?? 'all');
                            },
                            decoration: const InputDecoration(
                                labelText: 'Type',
                                prefixIcon: Icon(Icons.swap_vert_rounded)),
                          ),
                        ),
                      ],
                    );
                  }),
                  const SizedBox(height: 10),
                  LayoutBuilder(builder: (context, constraints) {
                    final stacked = constraints.maxWidth < 520;
                    final fieldWidth = stacked
                        ? constraints.maxWidth
                        : (constraints.maxWidth - 10) / 2;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        SizedBox(
                          width: fieldWidth,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.date_range_rounded),
                            label: Text(
                              widget.dateRange == null
                                  ? 'Date range'
                                  : '${widget.dateRange!.start.month}/${widget.dateRange!.start.day} – ${widget.dateRange!.end.month}/${widget.dateRange!.end.day}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onPressed: () async {
                              final now = DateTime.now();
                              final selected = await showDateRangePicker(
                                context: context,
                                firstDate: DateTime(2000),
                                lastDate: DateTime(now.year + 1),
                                initialDateRange: widget.dateRange,
                              );
                              widget.onDateRangeChanged(selected);
                            },
                          ),
                        ),
                        SizedBox(
                          width: fieldWidth,
                          child: DropdownButtonFormField<String>(
                            value: widget.sortMode,
                            items: const [
                              DropdownMenuItem(
                                  value: 'newest', child: Text('Newest')),
                              DropdownMenuItem(
                                  value: 'oldest', child: Text('Oldest')),
                              DropdownMenuItem(
                                  value: 'amount_high',
                                  child: Text('Amount: high')),
                              DropdownMenuItem(
                                  value: 'amount_low',
                                  child: Text('Amount: low')),
                            ],
                            onChanged: (value) {
                              if (value != null) widget.onSortChanged(value);
                            },
                            decoration: const InputDecoration(
                              labelText: 'Sort',
                              prefixIcon: Icon(Icons.sort_rounded),
                            ),
                          ),
                        ),
                        if (widget.dateRange != null)
                          ActionChip(
                            avatar: const Icon(Icons.close_rounded, size: 16),
                            label: const Text('Clear date'),
                            onPressed: () => widget.onDateRangeChanged(null),
                          ),
                      ],
                    );
                  }),
                ],
              ),
            ),
            Expanded(
              child: widget.transactions.isEmpty
                  ? _TransactionsEmptyState(
                      hasTransactions: widget.hasTransactions,
                      onAddTransaction: widget.onAddTransaction,
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: widget.transactions.length,
                      itemBuilder: (context, index) {
                        final transaction = widget.transactions[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TransactionTile(
                            transaction: transaction,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Edit transaction',
                                  onPressed: () => widget.onEdit(transaction),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  tooltip: 'Delete transaction',
                                  onPressed: () => showDialog(
                                    context: context,
                                    builder: (_) => AlertDialog(
                                      title: const Text('Delete transaction?'),
                                      content: Text(
                                          'Delete ${transaction.category}?'),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            child: const Text('Cancel')),
                                        FilledButton(
                                          onPressed: () async {
                                            Navigator.pop(context);
                                            await widget
                                                .onDelete(transaction.id);
                                          },
                                          child: const Text('Delete'),
                                        ),
                                      ],
                                    ),
                                  ),
                                  icon:
                                      const Icon(Icons.delete_outline_rounded),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransactionsEmptyState extends StatelessWidget {
  const _TransactionsEmptyState({
    required this.hasTransactions,
    required this.onAddTransaction,
  });

  final bool hasTransactions;
  final VoidCallback onAddTransaction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  hasTransactions
                      ? Icons.filter_list_off_rounded
                      : Icons.receipt_long_outlined,
                  color: colors.primary,
                  size: 36,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                hasTransactions
                    ? 'No matching transactions'
                    : 'No transactions yet',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                hasTransactions
                    ? 'Try changing your search or filters.'
                    : 'Start tracking your money by adding your first transaction.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
              ),
              if (!hasTransactions) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: onAddTransaction,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add transaction'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class AddTransactionView extends StatefulWidget {
  const AddTransactionView({
    super.key,
    required this.categories,
    required this.incomeSources,
    required this.existingSmsFingerprints,
    required this.onSaved,
    required this.prefs,
    required this.onCategoriesChanged,
    required this.initialType,
    this.quickAction,
    this.onQuickActionHandled,
  });

  final List<CategoryRecord> categories;
  final List<String> incomeSources;
  final Set<String> existingSmsFingerprints;
  final SharedPreferences prefs;
  final Future<void> Function() onCategoriesChanged;
  final TransactionType initialType;
  final String? quickAction;
  final VoidCallback? onQuickActionHandled;
  final Future<void> Function({
    required TransactionType type,
    required double amount,
    required String category,
    required String incomeSource,
    required String description,
    required String merchant,
    required String paymentMethod,
    required String source,
    required DateTime date,
    String receiptImage,
    String smsFingerprint,
  }) onSaved;

  @override
  State<AddTransactionView> createState() => _AddTransactionViewState();
}

class _SmsCandidate {
  const _SmsCandidate({
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
    required this.classification,
  });

  final double amount;
  final TransactionType type;
  final String merchant;
  final DateTime date;
  final String message;
  final String sender;
  final String paymentMethod;
  final String service;
  final String reference;
  final String fingerprint;
  final String contentFingerprint;
  final String classification;

  _SmsCandidate copyWith({
    double? amount,
    String? merchant,
    DateTime? date,
    String? paymentMethod,
    String? service,
    String? reference,
    String? classification,
  }) =>
      _SmsCandidate(
        amount: amount ?? this.amount,
        type: type,
        merchant: merchant ?? this.merchant,
        date: date ?? this.date,
        message: message,
        sender: sender,
        paymentMethod: paymentMethod ?? this.paymentMethod,
        service: service ?? this.service,
        reference: reference ?? this.reference,
        fingerprint: fingerprint,
        contentFingerprint: contentFingerprint,
        classification: classification ?? this.classification,
      );
}

enum _ReceiptReviewAction { edit, save, rescan }

class _ReceiptReviewData {
  const _ReceiptReviewData({
    required this.merchant,
    required this.amount,
    required this.date,
    required this.category,
    required this.description,
  });

  final String merchant;
  final String amount;
  final DateTime? date;
  final String category;
  final String description;
}

class _ReceiptReviewDecision {
  const _ReceiptReviewDecision(this.action, this.data);

  final _ReceiptReviewAction action;
  final _ReceiptReviewData data;
}

class _AddTransactionViewState extends State<AddTransactionView> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _merchantController = TextEditingController();
  final _descriptionController = TextEditingController();
  TransactionType _transactionType = TransactionType.expense;
  String _selectedCategory = '';
  String _selectedIncomeSource = 'Salary';
  String _selectedMethod = 'UPI';
  String _selectedSource = 'manual';
  Uint8List? _receiptBytes;
  DateTime _transactionDate = DateTime.now();
  bool _isSaving = false;
  bool _isScanningReceipt = false;
  bool _receiptDateNeedsReview = false;
  String? _defaultCategoryAtBuild;
  String? _defaultMethodAtBuild;
  static const MethodChannel _smsChannel = MethodChannel('trackyo/sms');

  @override
  void initState() {
    super.initState();
    _transactionType = widget.initialType;
    _defaultMethodAtBuild =
        widget.prefs.getString('trackyo_default_payment_method');
    if (const ['UPI', 'Cash', 'Card', 'Bank Transfer']
        .contains(_defaultMethodAtBuild)) {
      _selectedMethod = _defaultMethodAtBuild!;
    }
    _defaultCategoryAtBuild =
        widget.prefs.getString('trackyo_default_transaction_category');
    final preferredCategory = _defaultCategoryAtBuild;
    if (preferredCategory != null &&
        widget.categories.any((item) => item.name == preferredCategory)) {
      _selectedCategory = preferredCategory;
    }
    if (widget.incomeSources.isNotEmpty &&
        !widget.incomeSources.contains(_selectedIncomeSource)) {
      _selectedIncomeSource = widget.incomeSources.first;
    }
    if (widget.categories.isNotEmpty &&
        !widget.categories.any((item) => item.name == _selectedCategory)) {
      final preferredCategory =
          widget.prefs.getString('trackyo_default_transaction_category');
      _selectedCategory =
          widget.categories.any((item) => item.name == preferredCategory)
              ? preferredCategory!
              : widget.categories.first.name;
    }
  }

  @override
  void didUpdateWidget(covariant AddTransactionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final preferredMethod =
        widget.prefs.getString('trackyo_default_payment_method');
    if (preferredMethod != _defaultMethodAtBuild) {
      _defaultMethodAtBuild = preferredMethod;
      if (const ['UPI', 'Cash', 'Card', 'Bank Transfer']
          .contains(preferredMethod)) {
        _selectedMethod = preferredMethod!;
      }
    }
    final preferredCategory =
        widget.prefs.getString('trackyo_default_transaction_category');
    if (preferredCategory != _defaultCategoryAtBuild) {
      _defaultCategoryAtBuild = preferredCategory;
      if (widget.categories.any((item) => item.name == preferredCategory)) {
        _selectedCategory = preferredCategory!;
      }
    }
    if (oldWidget.initialType != widget.initialType) {
      _transactionType = widget.initialType;
    }
    if (widget.quickAction != null &&
        widget.quickAction != oldWidget.quickAction) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.quickAction == 'receipt') {
          unawaited(_chooseReceiptSource());
        } else if (widget.quickAction == 'sms') {
          unawaited(_scanSms());
        }
        widget.onQuickActionHandled?.call();
      });
    }
    if (widget.incomeSources.isNotEmpty &&
        !widget.incomeSources.contains(_selectedIncomeSource)) {
      _selectedIncomeSource = widget.incomeSources.first;
    }
    if (widget.categories.isNotEmpty &&
        !widget.categories.any((item) => item.name == _selectedCategory)) {
      _selectedCategory = widget.categories.first.name;
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _merchantController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _chooseReceiptSource() async {
    if (_isScanningReceipt || _isSaving) return;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source != null) await _pickReceiptImage(source);
  }

  Future<void> _pickReceiptImage(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
          source: source, imageQuality: 85, maxWidth: 2000);
      if (image == null) return;
      final bytes = await image.readAsBytes();
      if (bytes.length > 6 * 1024 * 1024) {
        if (mounted) {
          _showSnack(context, 'Receipt image must be smaller than 6 MB.');
        }
        return;
      }

      final ocrSupported = !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);
      var scanResult = parseReceiptText('');
      var scanError = !ocrSupported ? receiptOcrFailureMessage : '';
      if (ocrSupported) {
        setState(() => _isScanningReceipt = true);
      }
      try {
        if (ocrSupported) {
          final recognizer =
              TextRecognizer(script: TextRecognitionScript.latin);
          late final ReceiptOcrOutcome outcome;
          try {
            outcome = await recognizeReceiptText(() async {
              final recognized = await recognizer.processImage(
                InputImage.fromFilePath(image.path),
              );
              if (kDebugMode) {
                _logReceiptOcrText('raw ML Kit', recognized.text);
                _logReceiptOcrText(
                  'normalized receipt lines',
                  recognized.text
                      .trim()
                      .split(RegExp(r'[\r\n]+'))
                      .map((line) => line.trim())
                      .where((line) => line.isNotEmpty)
                      .join('\n'),
                );
              }
              return recognized.text;
            });
          } finally {
            try {
              await recognizer.close().timeout(const Duration(seconds: 3));
            } catch (_) {
              // Native recognizer cleanup must not block receipt review.
            }
          }
          scanResult = outcome.result;
          scanError = outcome.error;
          if (kDebugMode) {
            debugPrint(
              '[TrackYo receipt OCR] parsed amount=${scanResult.amount}, '
              'labeled=${scanResult.amountIsLabeled}, '
              'merchant=${scanResult.merchant}, date=${scanResult.date}',
            );
          }
        }
      } finally {
        if (mounted && ocrSupported) {
          setState(() => _isScanningReceipt = false);
        }
      }
      if (!mounted) return;
      if (kDebugMode) {
        debugPrint(
          '[TrackYo receipt OCR] opening review with '
          'amount=${scanResult.amount}, scanError=$scanError',
        );
      }
      await _reviewReceipt(bytes, scanResult, scanError: scanError);
    } on PlatformException catch (error) {
      if (!mounted || error.code == 'already_active') return;
      _showSnack(
        context,
        source == ImageSource.camera
            ? 'Camera access was unavailable or denied. Choose an image from your gallery or enter receipt details manually.'
            : 'Photo access was unavailable or denied. You can still enter receipt details manually.',
      );
    } catch (error) {
      if (mounted) {
        _showSnack(context, receiptOcrFailureMessage);
      }
    }
  }

  void _logReceiptOcrText(String stage, String text) {
    final encodedText = jsonEncode(text);
    debugPrintSynchronously(
      '[TrackYo receipt OCR] $stage JSON begin (${text.length} chars)',
    );
    const chunkSize = 700;
    for (var start = 0; start < encodedText.length; start += chunkSize) {
      final end = (start + chunkSize).clamp(0, encodedText.length);
      debugPrintSynchronously(
        '[TrackYo receipt OCR] $stage JSON[$start:$end] '
        '${encodedText.substring(start, end)}',
      );
    }
    debugPrintSynchronously('[TrackYo receipt OCR] $stage JSON end');
  }

  Future<void> _reviewReceipt(
    Uint8List imageBytes,
    ReceiptScanResult result, {
    required String scanError,
  }) async {
    final categoryNames = widget.categories.map((item) => item.name).toList();
    final suggestedCategory = suggestReceiptCategory(
      merchant: result.merchant,
      items: result.items,
      categories: categoryNames,
    );
    final review = await Navigator.of(context).push<_ReceiptReviewDecision>(
      MaterialPageRoute(
        builder: (_) => _ReceiptReviewScreen(
          imageBytes: imageBytes,
          result: result,
          categories: categoryNames,
          initialCategory: suggestedCategory ??
              (categoryNames.contains(_selectedCategory)
                  ? _selectedCategory
                  : categoryNames.isNotEmpty
                      ? categoryNames.first
                      : ''),
          scanError: scanError,
        ),
      ),
    );
    if (!mounted || review == null) return;
    if (review.action == _ReceiptReviewAction.rescan) {
      await _chooseReceiptSource();
      return;
    }
    setState(() {
      _transactionType = TransactionType.expense;
      _amountController.text = review.data.amount;
      _merchantController.text = review.data.merchant;
      _descriptionController.text = review.data.description;
      if (review.data.date != null) {
        _transactionDate = review.data.date!;
      }
      _receiptDateNeedsReview = review.data.date == null;
      _selectedCategory = review.data.category;
      _selectedSource = 'receipt';
      _receiptBytes = imageBytes;
    });
    if (review.action == _ReceiptReviewAction.edit) {
      _showSnack(context, 'Receipt details copied to the expense form.');
      return;
    }
    await _submit();
  }

  Future<void> _scanSms() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      if (mounted) {
        _showSnack(context, 'SMS scanning is available on Android devices.');
      }
      return;
    }
    if (widget.prefs.getBool('trackyo_sms_scanning_enabled') == false) {
      _showSnack(context,
          'SMS scanning is turned off. Enable it in Profile settings to continue.');
      return;
    }
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Scan transaction messages?'),
        content: const Text(
            'Allow READ_SMS so TrackYo can check recent messages on this device for bank and UPI transactions. Messages are processed locally. Only transactions you select and confirm are saved; the rest of each message is not uploaded.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue')),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    try {
      final permission = await _smsChannel.invokeMapMethod<String, dynamic>(
        'requestReadPermission',
      );
      if (permission?['granted'] != true) {
        final permanentlyDenied = permission?['permanentlyDenied'] == true;
        if (mounted) {
          _showSnack(
            context,
            permanentlyDenied
                ? 'SMS permission is disabled. Enable it in Android Settings to scan, or add the transaction manually.'
                : 'SMS permission was denied. You can still add transactions manually.',
          );
        }
        return;
      }
      final messages =
          await _smsChannel.invokeMethod<List<dynamic>>('readRecentMessages') ??
              const [];
      final fingerprints = <String>{};
      var duplicateCount = 0;
      var skippedCount = 0;
      final candidates = <_SmsCandidate>[];
      for (final item in messages) {
        try {
          if (item is! Map) {
            skippedCount++;
            continue;
          }
          final candidate = _parseSmsCandidate(Map<String, dynamic>.from(item));
          if (candidate == null) {
            skippedCount++;
            continue;
          }
          if (widget.existingSmsFingerprints.contains(candidate.fingerprint) ||
              widget.existingSmsFingerprints
                  .contains(candidate.contentFingerprint) ||
              fingerprints.contains(candidate.fingerprint) ||
              fingerprints.contains(candidate.contentFingerprint)) {
            duplicateCount++;
            continue;
          }
          fingerprints
            ..add(candidate.fingerprint)
            ..add(candidate.contentFingerprint);
          candidates.add(candidate);
        } catch (_) {
          skippedCount++;
        }
      }
      candidates.sort((a, b) => b.date.compareTo(a.date));
      if (!mounted) return;
      if (candidates.isEmpty) {
        final message = duplicateCount > 0
            ? 'No new transactions found. $duplicateCount duplicate message${duplicateCount == 1 ? '' : 's'} skipped.'
            : skippedCount > 0
                ? 'No supported transactions found. $skippedCount message${skippedCount == 1 ? '' : 's'} could not be parsed.'
                : 'No recent SMS messages were found. You can enter a transaction manually.';
        _showSnack(context, message);
        return;
      }
      final selected = await Navigator.of(context).push<List<_SmsCandidate>>(
        MaterialPageRoute(
          builder: (_) => _SmsReviewScreen(
            candidates: candidates,
            categories: widget.categories.map((item) => item.name).toList(),
            incomeSources: widget.incomeSources,
          ),
        ),
      );
      if (selected == null || !mounted) return;
      var addedCount = 0;
      var failedCount = 0;
      String? saveError;
      for (final candidate in selected) {
        if (widget.existingSmsFingerprints.contains(candidate.fingerprint) ||
            widget.existingSmsFingerprints
                .contains(candidate.contentFingerprint)) {
          duplicateCount++;
          continue;
        }
        try {
          await widget.onSaved(
            type: candidate.type,
            amount: candidate.amount,
            category: candidate.type == TransactionType.expense
                ? candidate.classification
                : '',
            incomeSource: candidate.type == TransactionType.income
                ? candidate.classification
                : '',
            description: [
              if (candidate.service.isNotEmpty) candidate.service,
              if (candidate.reference.isNotEmpty) 'Ref ${candidate.reference}',
            ].join(' • '),
            merchant: candidate.merchant,
            paymentMethod: candidate.paymentMethod,
            source: 'sms',
            date: candidate.date,
            smsFingerprint: candidate.fingerprint,
          );
          addedCount++;
        } catch (error) {
          failedCount++;
          saveError ??= error.toString();
        }
      }
      if (mounted) {
        _showSnack(
          context,
          [
            if (addedCount > 0)
              '$addedCount transaction${addedCount == 1 ? '' : 's'} saved',
            if (duplicateCount > 0)
              '$duplicateCount duplicate${duplicateCount == 1 ? '' : 's'} skipped',
            if (failedCount > 0)
              '$failedCount transaction${failedCount == 1 ? '' : 's'} could not be saved${saveError == null ? '' : ': $saveError'}',
            if (addedCount == 0 && duplicateCount == 0)
              'No transactions were saved.',
          ].join(' • '),
        );
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      _showSnack(
          context,
          error.code == 'permission_denied'
              ? 'SMS permission was denied. You can still add transactions manually.'
              : error.code == 'unsupported_device'
                  ? 'SMS scanning is not supported on this device. You can add the transaction manually.'
                  : 'Unable to scan SMS messages. You can still add transactions manually.');
    } catch (_) {
      if (mounted) {
        _showSnack(context,
            'Unable to scan SMS messages. You can still add transactions manually.');
      }
    }
  }

  _SmsCandidate? _parseSmsCandidate(Map<String, dynamic> sms) {
    final parsed = parseSmsTransaction(sms);
    if (parsed == null) return null;
    return _SmsCandidate(
      amount: parsed.amount,
      type: parsed.type == 'income'
          ? TransactionType.income
          : TransactionType.expense,
      merchant: parsed.merchant,
      date: parsed.date,
      message: parsed.message,
      sender: parsed.sender,
      paymentMethod: parsed.paymentMethod,
      service: parsed.service,
      reference: parsed.reference,
      fingerprint: parsed.fingerprint,
      contentFingerprint: parsed.contentFingerprint,
      classification: parsed.type == 'income'
          ? suggestSmsIncomeSource(
              message: parsed.message,
              incomeSources: widget.incomeSources,
            )
          : suggestReceiptCategory(
                merchant: parsed.merchant,
                items: const [],
                categories: widget.categories.map((item) => item.name).toList(),
              ) ??
              (widget.categories.any((item) => item.name == 'Other')
                  ? 'Other'
                  : widget.categories.isNotEmpty
                      ? widget.categories.first.name
                      : ''),
    );
  }

  Future<void> _submit() async {
    if (_selectedSource == 'receipt' && _receiptDateNeedsReview) {
      _showSnack(context, 'Choose the receipt transaction date before saving.');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    final amount = double.tryParse(_amountController.text) ?? 0;
    if (amount <= 0) {
      _showSnack(context, 'Enter a valid amount');
      return;
    }

    setState(() => _isSaving = true);
    try {
      await widget.onSaved(
        type: _transactionType,
        amount: amount,
        category: _transactionType == TransactionType.expense
            ? _selectedCategory
            : '',
        incomeSource: _transactionType == TransactionType.income
            ? _selectedIncomeSource
            : '',
        description: _descriptionController.text.trim(),
        merchant: _transactionType == TransactionType.income
            ? ''
            : _merchantController.text.trim(),
        paymentMethod: _selectedMethod,
        source: _selectedSource,
        date: _transactionDate,
      );
      if (!mounted) return;
      _amountController.clear();
      _merchantController.clear();
      _descriptionController.clear();
      setState(() {
        _receiptBytes = null;
        _transactionDate = DateTime.now();
        _selectedSource = 'manual';
        _receiptDateNeedsReview = false;
      });
      _showSnack(context, 'Transaction saved');
    } catch (error) {
      if (!mounted) return;
      _showSnack(context, error.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_transactionType == TransactionType.expense
                ? 'Add expense'
                : 'Add income'),
            Text('Record it now. Stay on top of it.',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 36),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        SegmentedButton<TransactionType>(
                          selected: {_transactionType},
                          onSelectionChanged: (value) =>
                              setState(() => _transactionType = value.first),
                          showSelectedIcon: false,
                          style: SegmentedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            textStyle:
                                const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          segments: const [
                            ButtonSegment(
                                icon: Icon(Icons.arrow_downward_rounded),
                                value: TransactionType.expense,
                                label: Text('Expense')),
                            ButtonSegment(
                                icon: Icon(Icons.arrow_upward_rounded),
                                value: TransactionType.income,
                                label: Text('Income')),
                          ],
                        ),
                        const SizedBox(height: 18),
                        TextFormField(
                          controller: _amountController,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          validator: (value) => value == null ||
                                  value.trim().isEmpty ||
                                  double.tryParse(value) == null
                              ? 'Enter a valid amount'
                              : null,
                          decoration: const InputDecoration(
                            labelText: 'Amount',
                            hintText: '0.00',
                            prefixIcon: Icon(Icons.currency_rupee_rounded),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_transactionType == TransactionType.expense) ...[
                          DropdownButtonFormField<String>(
                            value: _selectedCategory,
                            validator: (value) => value == null || value.isEmpty
                                ? 'Choose an expense category'
                                : null,
                            items: widget.categories.isEmpty
                                ? const [
                                    DropdownMenuItem(
                                      value: '',
                                      child: Text('No categories available'),
                                    )
                                  ]
                                : widget.categories
                                    .map((category) => DropdownMenuItem(
                                        value: category.name,
                                        child: Text(category.name)))
                                    .toList(),
                            onChanged: (value) =>
                                setState(() => _selectedCategory = value ?? ''),
                            decoration: const InputDecoration(
                              labelText: 'Category',
                              prefixIcon: Icon(Icons.sell_outlined),
                            ),
                          ),
                          if (widget.categories.isEmpty)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () async {
                                  await Navigator.of(context)
                                      .push(MaterialPageRoute<void>(
                                    builder: (_) => CategoryManagementScreen(
                                        prefs: widget.prefs),
                                  ));
                                  if (mounted) {
                                    await widget.onCategoriesChanged();
                                  }
                                },
                                icon: const Icon(Icons.add),
                                label: const Text('Create a category'),
                              ),
                            ),
                        ] else
                          DropdownButtonFormField<String>(
                            value: widget.incomeSources
                                    .contains(_selectedIncomeSource)
                                ? _selectedIncomeSource
                                : null,
                            validator: (value) => value == null || value.isEmpty
                                ? 'Choose an income source'
                                : null,
                            items: widget.incomeSources
                                .map((source) => DropdownMenuItem(
                                    value: source, child: Text(source)))
                                .toList(),
                            onChanged: (value) => setState(
                                () => _selectedIncomeSource = value ?? ''),
                            decoration: const InputDecoration(
                              labelText: 'Income source',
                              prefixIcon:
                                  Icon(Icons.account_balance_wallet_outlined),
                            ),
                          ),
                        const SizedBox(height: 16),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.calendar_today_outlined),
                          title: const Text('Transaction date'),
                          subtitle: Text(_transactionDate
                              .toLocal()
                              .toString()
                              .substring(0, 10)),
                          trailing: const Icon(Icons.edit_calendar_outlined),
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _transactionDate,
                              firstDate: DateTime(2000),
                              lastDate:
                                  DateTime.now().add(const Duration(days: 366)),
                            );
                            if (picked != null) {
                              setState(() {
                                _transactionDate = picked;
                                _receiptDateNeedsReview = false;
                              });
                            }
                          },
                        ),
                        if (_receiptDateNeedsReview)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: Text(
                              'Receipt date was not detected. Choose the transaction date before saving.',
                              style: TextStyle(color: Color(0xFFE5A13E)),
                            ),
                          ),
                        if (_transactionType == TransactionType.expense) ...[
                          TextFormField(
                            controller: _merchantController,
                            decoration: const InputDecoration(
                              labelText: 'Merchant',
                              prefixIcon: Icon(Icons.storefront_outlined),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        DropdownButtonFormField<String>(
                          value: _selectedMethod,
                          items: const [
                            DropdownMenuItem(value: 'UPI', child: Text('UPI')),
                            DropdownMenuItem(
                                value: 'Cash', child: Text('Cash')),
                            DropdownMenuItem(
                                value: 'Credit Card',
                                child: Text('Credit Card')),
                            DropdownMenuItem(
                                value: 'Debit Card', child: Text('Debit Card')),
                            DropdownMenuItem(
                                value: 'Bank Transfer',
                                child: Text('Bank Transfer')),
                          ],
                          onChanged: (value) =>
                              setState(() => _selectedMethod = value ?? 'UPI'),
                          decoration: const InputDecoration(
                            labelText: 'Payment method',
                            prefixIcon: Icon(Icons.payments_outlined),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _descriptionController,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: 'Description',
                            alignLabelWithHint: true,
                            prefixIcon: Icon(Icons.notes_rounded),
                          ),
                        ),
                        const SizedBox(height: 18),
                        if (_isScanningReceipt)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 14),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                                SizedBox(width: 10),
                                Text('Scanning receipt...'),
                              ],
                            ),
                          ),
                        if (_receiptBytes != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Image.memory(
                              _receiptBytes!,
                              height: 180,
                              width: double.infinity,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  const EmptyState(
                                      message:
                                          'Receipt image attached. Preview unavailable.'),
                            ),
                          ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            if (_transactionType == TransactionType.expense)
                              Expanded(
                                  child: OutlinedButton.icon(
                                      onPressed: _isScanningReceipt || _isSaving
                                          ? null
                                          : _chooseReceiptSource,
                                      icon: const Icon(
                                          Icons.document_scanner_outlined),
                                      label: const Text('Scan receipt'))),
                            if (_transactionType == TransactionType.expense)
                              const SizedBox(width: 10),
                            Expanded(
                                child: OutlinedButton.icon(
                                    onPressed: _isScanningReceipt || _isSaving
                                        ? null
                                        : _scanSms,
                                    icon: const Icon(Icons.sms_rounded),
                                    label: const Text('SMS scan'))),
                          ],
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _isSaving || _isScanningReceipt
                                ? null
                                : _submit,
                            icon: _isSaving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.save_rounded),
                            label: Text(
                                _isSaving ? 'Saving...' : 'Save transaction'),
                            style: FilledButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16))),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReceiptReviewScreen extends StatefulWidget {
  const _ReceiptReviewScreen({
    required this.imageBytes,
    required this.result,
    required this.categories,
    required this.initialCategory,
    required this.scanError,
  });

  final Uint8List imageBytes;
  final ReceiptScanResult result;
  final List<String> categories;
  final String initialCategory;
  final String scanError;

  @override
  State<_ReceiptReviewScreen> createState() => _ReceiptReviewScreenState();
}

class _ReceiptReviewScreenState extends State<_ReceiptReviewScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _merchantController;
  late final TextEditingController _amountController;
  late final TextEditingController _descriptionController;
  DateTime? _date;
  late String _category;
  bool _missingDateError = false;

  @override
  void initState() {
    super.initState();
    _merchantController =
        TextEditingController(text: widget.result.merchant ?? '');
    _amountController = TextEditingController(
      text: widget.result.amount?.toStringAsFixed(2) ?? '',
    );
    _descriptionController =
        TextEditingController(text: widget.result.description);
    _date = widget.result.date;
    _category = widget.categories.contains(widget.initialCategory)
        ? widget.initialCategory
        : '';
  }

  @override
  void dispose() {
    _merchantController.dispose();
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  _ReceiptReviewData _data() => _ReceiptReviewData(
        merchant: _merchantController.text.trim(),
        amount: _amountController.text.trim(),
        date: _date,
        category: _category,
        description: _descriptionController.text.trim(),
      );

  void _return(_ReceiptReviewAction action) {
    if (action == _ReceiptReviewAction.save &&
        !_formKey.currentState!.validate()) {
      return;
    }
    if (action == _ReceiptReviewAction.save && _date == null) {
      setState(() => _missingDateError = true);
      return;
    }
    if (action != _ReceiptReviewAction.rescan &&
        _category.isEmpty &&
        widget.categories.isNotEmpty) {
      setState(() {});
      return;
    }
    Navigator.of(context).pop(_ReceiptReviewDecision(action, _data()));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final lowConfidence =
        widget.result.isLowConfidence || widget.scanError.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review receipt'),
        leading: IconButton(
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = math.min(constraints.maxWidth - 32, 720.0);
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
              child: Center(
                child: SizedBox(
                  width: width,
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Image.memory(
                            widget.imageBytes,
                            height: 230,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) =>
                                const SizedBox(
                              height: 140,
                              child: Center(
                                  child: Text('Receipt preview unavailable')),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: (lowConfidence
                                    ? colors.tertiary
                                    : const Color(0xFF38B89A))
                                .withOpacity(0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                lowConfidence
                                    ? Icons.info_outline_rounded
                                    : Icons.check_circle_outline_rounded,
                                color: lowConfidence
                                    ? colors.tertiary
                                    : const Color(0xFF38B89A),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  widget.scanError.isNotEmpty
                                      ? widget.scanError
                                      : lowConfidence
                                          ? 'Some details could not be detected. Please review before saving.'
                                          : 'Receipt scanned successfully. Check the details before saving.',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _merchantController,
                          decoration: InputDecoration(
                            labelText: 'Merchant',
                            prefixIcon: const Icon(Icons.storefront_outlined),
                            helperText: widget.result.merchant == null
                                ? 'Not detected — enter the merchant'
                                : null,
                            filled: widget.result.merchant == null,
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _amountController,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                            labelText: 'Amount',
                            prefixIcon:
                                const Icon(Icons.currency_rupee_rounded),
                            helperText: widget.result.amount == null
                                ? 'Total amount not detected — please enter manually.'
                                : widget.result.amountIsLabeled
                                    ? null
                                    : 'Estimated from printed amounts — please verify',
                            filled: widget.result.amount == null ||
                                !widget.result.amountIsLabeled,
                          ),
                          validator: (value) {
                            final amount = double.tryParse(value?.trim() ?? '');
                            if (amount == null || amount <= 0) {
                              return 'Enter a valid receipt total';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.calendar_month_outlined),
                          title: const Text('Date'),
                          subtitle: Text(_date == null
                              ? 'Not detected — choose the receipt date'
                              : '${_date!.day.toString().padLeft(2, '0')}/${_date!.month.toString().padLeft(2, '0')}/${_date!.year}'),
                          trailing: const Icon(Icons.edit_calendar_outlined),
                          tileColor: _date == null
                              ? colors.tertiary.withOpacity(0.08)
                              : null,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          onTap: () async {
                            final selected = await showDatePicker(
                              context: context,
                              initialDate: _date ?? DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate:
                                  DateTime.now().add(const Duration(days: 366)),
                            );
                            if (selected != null) {
                              setState(() {
                                _date = selected;
                                _missingDateError = false;
                              });
                            }
                          },
                        ),
                        if (_missingDateError)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Text(
                              'Choose a transaction date before saving.',
                              style: TextStyle(color: colors.error),
                            ),
                          ),
                        if (widget.categories.isNotEmpty)
                          DropdownButtonFormField<String>(
                            value: _category.isEmpty ? null : _category,
                            decoration: const InputDecoration(
                              labelText: 'Category',
                              prefixIcon: Icon(Icons.sell_outlined),
                            ),
                            items: widget.categories
                                .map((category) => DropdownMenuItem(
                                      value: category,
                                      child: Text(category),
                                    ))
                                .toList(),
                            onChanged: (value) =>
                                setState(() => _category = value ?? ''),
                            validator: (value) =>
                                value == null ? 'Choose a category' : null,
                          )
                        else
                          const Text(
                              'Create an expense category before saving this receipt.'),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _descriptionController,
                          minLines: 2,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            labelText: 'Description',
                            alignLabelWithHint: true,
                            prefixIcon: Icon(Icons.notes_rounded),
                          ),
                        ),
                        if (widget.result.items.isNotEmpty ||
                            widget.result.tax != null ||
                            widget.result.invoiceNumber != null) ...[
                          const SizedBox(height: 14),
                          _DashboardPanel(
                            title: 'Detected bill details',
                            icon: Icons.receipt_long_outlined,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final item in widget.result.items)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 5),
                                    child: Row(
                                      children: [
                                        Expanded(child: Text(item.name)),
                                        Text(formatCurrency(item.amount)),
                                      ],
                                    ),
                                  ),
                                if (widget.result.tax != null)
                                  Text(
                                      'Tax / GST: ${formatCurrency(widget.result.tax!)}'),
                                if (widget.result.invoiceNumber != null)
                                  Text(
                                      'Bill number: ${widget.result.invoiceNumber}'),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () =>
                                    _return(_ReceiptReviewAction.rescan),
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('Rescan'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () =>
                                    _return(_ReceiptReviewAction.edit),
                                child: const Text('Edit'),
                              ),
                            ),
                          ],
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                        FilledButton.icon(
                          onPressed: widget.categories.isEmpty
                              ? null
                              : () => _return(_ReceiptReviewAction.save),
                          icon: const Icon(Icons.save_rounded),
                          label: const Text('Save Expense'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SmsReviewScreen extends StatefulWidget {
  const _SmsReviewScreen({
    required this.candidates,
    required this.categories,
    required this.incomeSources,
  });

  final List<_SmsCandidate> candidates;
  final List<String> categories;
  final List<String> incomeSources;

  @override
  State<_SmsReviewScreen> createState() => _SmsReviewScreenState();
}

class _SmsReviewScreenState extends State<_SmsReviewScreen> {
  late List<_SmsCandidate> _candidates;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _candidates = widget.candidates.take(50).toList();
    _candidates.sort((a, b) => b.date.compareTo(a.date));
  }

  Future<void> _editCandidate(_SmsCandidate candidate) async {
    final updated = await showDialog<_SmsCandidate>(
      context: context,
      builder: (_) => _SmsCandidateEditor(
        candidate: candidate,
        categories: widget.categories,
        incomeSources: widget.incomeSources,
      ),
    );
    if (updated == null || !mounted) return;
    setState(() {
      _candidates = [
        for (final item in _candidates)
          if (item.fingerprint == updated.fingerprint) updated else item,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recent SMS'),
        leading: IconButton(
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = math.min(constraints.maxWidth - 32, 760.0);
            return Column(
              children: [
                Expanded(
                  child: _candidates.isEmpty
                      ? const Center(
                          child: Text('All detected messages were ignored.'))
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          children: [
                            Center(
                              child: SizedBox(
                                width: width,
                                child: Column(
                                  children: [
                                    Text(
                                      'Newest relevant bank and UPI messages from the last 30 days appear first. Select transactions to save. Messages stay on this device; only confirmed transaction details are saved.',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium,
                                    ),
                                    const SizedBox(height: 12),
                                    for (final candidate in _candidates)
                                      Card(
                                        margin:
                                            const EdgeInsets.only(bottom: 12),
                                        clipBehavior: Clip.antiAlias,
                                        child: Column(
                                          children: [
                                            CheckboxListTile(
                                              value: _selected.contains(
                                                  candidate.fingerprint),
                                              onChanged: (value) {
                                                setState(() {
                                                  if (value == true) {
                                                    _selected.add(
                                                        candidate.fingerprint);
                                                  } else {
                                                    _selected.remove(
                                                        candidate.fingerprint);
                                                  }
                                                });
                                              },
                                              secondary: CircleAvatar(
                                                backgroundColor:
                                                    (candidate.type ==
                                                                TransactionType
                                                                    .income
                                                            ? const Color(
                                                                0xFF38B89A)
                                                            : const Color(
                                                                0xFFE77872))
                                                        .withOpacity(.12),
                                                child: Icon(
                                                  candidate.type ==
                                                          TransactionType.income
                                                      ? Icons
                                                          .arrow_downward_rounded
                                                      : Icons
                                                          .arrow_upward_rounded,
                                                  color: candidate.type ==
                                                          TransactionType.income
                                                      ? const Color(0xFF38B89A)
                                                      : const Color(0xFFE77872),
                                                ),
                                              ),
                                              title: Text(
                                                candidate.merchant,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              subtitle: Text(
                                                '${candidate.type == TransactionType.income ? 'Income' : 'Expense'} • ${candidate.date.toLocal().toString().substring(0, 16)}\n${candidate.paymentMethod} • ${candidate.service}',
                                              ),
                                              controlAffinity:
                                                  ListTileControlAffinity
                                                      .trailing,
                                            ),
                                            Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                      16, 0, 16, 8),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      formatCurrency(
                                                          candidate.amount),
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleMedium
                                                          ?.copyWith(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                              color: candidate
                                                                          .type ==
                                                                      TransactionType
                                                                          .income
                                                                  ? const Color(
                                                                      0xFF38B89A)
                                                                  : const Color(
                                                                      0xFFE77872)),
                                                    ),
                                                  ),
                                                  TextButton.icon(
                                                    onPressed: () =>
                                                        _editCandidate(
                                                            candidate),
                                                    icon: const Icon(
                                                        Icons.edit_outlined),
                                                    label: const Text('Edit'),
                                                  ),
                                                  TextButton.icon(
                                                    onPressed: () {
                                                      setState(() {
                                                        _selected.remove(
                                                            candidate
                                                                .fingerprint);
                                                        _candidates.removeWhere(
                                                            (item) =>
                                                                item.fingerprint ==
                                                                candidate
                                                                    .fingerprint);
                                                      });
                                                    },
                                                    icon: const Icon(
                                                        Icons.delete_outline),
                                                    label: const Text('Ignore'),
                                                    style: TextButton.styleFrom(
                                                        foregroundColor:
                                                            colors.error),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            if (candidate
                                                .classification.isNotEmpty)
                                              Padding(
                                                padding:
                                                    const EdgeInsets.fromLTRB(
                                                        16, 0, 16, 10),
                                                child: Align(
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: Chip(
                                                    avatar: Icon(
                                                      candidate.type ==
                                                              TransactionType
                                                                  .income
                                                          ? Icons
                                                              .account_balance_wallet_outlined
                                                          : Icons.sell_outlined,
                                                      size: 16,
                                                    ),
                                                    label: Text(candidate
                                                        .classification),
                                                  ),
                                                ),
                                              ),
                                            ExpansionTile(
                                              tilePadding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 16),
                                              title: const Text('Source SMS'),
                                              subtitle: Text(
                                                candidate.message,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              children: [
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.fromLTRB(
                                                          16, 0, 16, 16),
                                                  child: SelectableText(
                                                    candidate.message,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: width),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _selected.isEmpty
                            ? null
                            : () => Navigator.of(context).pop([
                                  for (final candidate in _candidates)
                                    if (_selected
                                        .contains(candidate.fingerprint))
                                      candidate,
                                ]),
                        icon: const Icon(Icons.save_rounded),
                        label: Text('Save selected (${_selected.length})'),
                        style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14)),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SmsCandidateEditor extends StatefulWidget {
  const _SmsCandidateEditor({
    required this.candidate,
    required this.categories,
    required this.incomeSources,
  });

  final _SmsCandidate candidate;
  final List<String> categories;
  final List<String> incomeSources;

  @override
  State<_SmsCandidateEditor> createState() => _SmsCandidateEditorState();
}

class _SmsCandidateEditorState extends State<_SmsCandidateEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amountController;
  late final TextEditingController _merchantController;
  late DateTime _date;
  late String _classification;

  List<String> get _classifications =>
      widget.candidate.type == TransactionType.income
          ? widget.incomeSources
          : widget.categories;

  @override
  void initState() {
    super.initState();
    _amountController =
        TextEditingController(text: widget.candidate.amount.toStringAsFixed(2));
    _merchantController =
        TextEditingController(text: widget.candidate.merchant);
    _date = widget.candidate.date;
    _classification = widget.candidate.classification;
    if (!_classifications.contains(_classification) &&
        _classifications.isNotEmpty) {
      _classification = _classifications.first;
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _merchantController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit detected transaction'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _amountController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                validator: (value) {
                  final amount = double.tryParse(value?.trim() ?? '');
                  return amount == null || amount <= 0
                      ? 'Enter a valid amount'
                      : null;
                },
                decoration: const InputDecoration(labelText: 'Amount'),
              ),
              TextFormField(
                controller: _merchantController,
                decoration: const InputDecoration(labelText: 'Merchant'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Date'),
                subtitle: Text(_date.toLocal().toString().substring(0, 16)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now().add(const Duration(days: 366)),
                  );
                  if (date != null) setState(() => _date = date);
                },
              ),
              if (_classifications.isNotEmpty)
                DropdownButtonFormField<String>(
                  value: _classifications.contains(_classification)
                      ? _classification
                      : _classifications.first,
                  items: _classifications
                      .map((item) =>
                          DropdownMenuItem(value: item, child: Text(item)))
                      .toList(),
                  onChanged: (value) =>
                      setState(() => _classification = value ?? ''),
                  decoration: InputDecoration(
                    labelText: widget.candidate.type == TransactionType.income
                        ? 'Income source'
                        : 'Expense category',
                  ),
                )
              else
                const Text(
                    'No matching category or income source is available.'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _classifications.isEmpty
              ? null
              : () {
                  if (!_formKey.currentState!.validate()) return;
                  Navigator.of(context).pop(
                    widget.candidate.copyWith(
                      amount: double.parse(_amountController.text),
                      merchant: _merchantController.text.trim(),
                      date: _date,
                      classification: _classification,
                    ),
                  );
                },
          child: const Text('Save changes'),
        ),
      ],
    );
  }
}

enum AnalyticsPeriod { thisWeek, thisMonth, lastMonth, thisYear, custom }

DateTimeRange analyticsPeriodRange(
  AnalyticsPeriod period,
  DateTime reference, {
  DateTimeRange? customRange,
}) {
  final today = DateTime(reference.year, reference.month, reference.day);
  switch (period) {
    case AnalyticsPeriod.thisWeek:
      final start = today.subtract(Duration(days: today.weekday - 1));
      return DateTimeRange(start: start, end: today);
    case AnalyticsPeriod.thisMonth:
      return DateTimeRange(
          start: DateTime(today.year, today.month), end: today);
    case AnalyticsPeriod.lastMonth:
      return DateTimeRange(
        start: DateTime(today.year, today.month - 1),
        end: DateTime(today.year, today.month, 0),
      );
    case AnalyticsPeriod.thisYear:
      return DateTimeRange(start: DateTime(today.year), end: today);
    case AnalyticsPeriod.custom:
      return customRange ?? DateTimeRange(start: today, end: today);
  }
}

class AnalyticsView extends StatefulWidget {
  const AnalyticsView({
    super.key,
    required this.transactions,
  });

  final List<TransactionRecord> transactions;

  @override
  State<AnalyticsView> createState() => _AnalyticsViewState();
}

class _AnalyticsViewState extends State<AnalyticsView> {
  AnalyticsPeriod _period = AnalyticsPeriod.thisMonth;
  DateTimeRange? _customRange;

  Future<void> _selectCustomRange() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange:
          _customRange ?? analyticsPeriodRange(AnalyticsPeriod.thisMonth, now),
    );
    if (range == null || !mounted) return;
    setState(() {
      _period = AnalyticsPeriod.custom;
      _customRange = DateTimeRange(
        start: DateTime(range.start.year, range.start.month, range.start.day),
        end: DateTime(range.end.year, range.end.month, range.end.day),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final range = analyticsPeriodRange(_period, DateTime.now(),
        customRange: _customRange);
    final transactions = widget.transactions.where((transaction) {
      final date = transaction.date;
      final day = DateTime(date.year, date.month, date.day);
      return !day.isBefore(range.start) && !day.isAfter(range.end);
    }).toList();
    final expenses = transactions
        .where((item) => item.type == TransactionType.expense)
        .toList();
    final incomes =
        transactions.where((item) => item.type == TransactionType.income);
    final totalExpenses =
        expenses.fold<double>(0, (total, item) => total + item.amount);
    final totalIncome =
        incomes.fold<double>(0, (total, item) => total + item.amount);
    final categoryTotals = <String, double>{};
    for (final item in expenses) {
      categoryTotals[item.category] =
          (categoryTotals[item.category] ?? 0) + item.amount;
    }
    final topCategories = categoryTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final incomeSourceTotals = <String, double>{};
    for (final transaction in incomes) {
      final source = transaction.classificationLabel;
      incomeSourceTotals[source] =
          (incomeSourceTotals[source] ?? 0) + transaction.amount;
    }
    final topIncomeSources = incomeSourceTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final monthlyTotals = <String, double>{};
    for (final item in expenses) {
      final key = '${item.date.year.toString().padLeft(4, '0')}-'
          '${item.date.month.toString().padLeft(2, '0')}';
      monthlyTotals[key] = (monthlyTotals[key] ?? 0) + item.amount;
    }
    final monthlyRows = monthlyTotals.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final highestExpense = expenses.isEmpty
        ? null
        : expenses.reduce((a, b) => a.amount >= b.amount ? a : b);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Analytics'),
            Text('A clearer picture of your finances',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: colors.onSurfaceVariant)),
          ],
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          final width = math.min(constraints.maxWidth - 36, 1120.0);
          final columns = width >= 760 ? 2 : 1;
          final panelWidth = columns == 2 ? (width - 14) / 2 : width;
          final metricWidth =
              columns == 2 ? (width - 20) / 3 : (width - 10) / 2;
          final hasTransactions = transactions.isNotEmpty;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            child: Center(
              child: SizedBox(
                width: width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Period',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _periodChip(AnalyticsPeriod.thisWeek, 'This week'),
                        _periodChip(AnalyticsPeriod.thisMonth, 'This month'),
                        _periodChip(AnalyticsPeriod.lastMonth, 'Last month'),
                        _periodChip(AnalyticsPeriod.thisYear, 'This year'),
                        OutlinedButton.icon(
                          onPressed: _selectCustomRange,
                          icon: const Icon(Icons.date_range_outlined, size: 18),
                          label: Text(_period == AnalyticsPeriod.custom
                              ? 'Custom'
                              : 'Custom range'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${_analyticsDate(range.start)} – ${_analyticsDate(range.end)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 14),
                    if (!hasTransactions) ...[
                      const _AnalyticsEmptyState(),
                      const SizedBox(height: 14),
                    ],
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        SizedBox(
                          width: metricWidth,
                          child: _MetricCard(
                              title: 'Income',
                              amount: formatCurrency(totalIncome),
                              icon: Icons.trending_up_rounded,
                              accent: const Color(0xFF38B89A)),
                        ),
                        SizedBox(
                          width: metricWidth,
                          child: _MetricCard(
                              title: 'Expenses',
                              amount: formatCurrency(totalExpenses),
                              icon: Icons.trending_down_rounded,
                              accent: const Color(0xFFE77872)),
                        ),
                        SizedBox(
                          width: metricWidth,
                          child: _MetricCard(
                              title: 'Net balance',
                              amount:
                                  formatCurrency(totalIncome - totalExpenses),
                              icon: Icons.account_balance_wallet_outlined,
                              accent: totalIncome >= totalExpenses
                                  ? const Color(0xFF6597DC)
                                  : const Color(0xFFE77872)),
                        ),
                      ],
                    ),
                    if (hasTransactions) ...[
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 14,
                        runSpacing: 14,
                        children: [
                          SizedBox(
                            width: panelWidth,
                            child: _DashboardPanel(
                              title: 'Spending by category',
                              icon: Icons.donut_small_rounded,
                              child: expenses.isEmpty
                                  ? const _InlineEmpty(
                                      message: 'No expenses in this period.')
                                  : SizedBox(
                                      height: math.max(
                                        176.0,
                                        topCategories.length * 40.0,
                                      ),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                            width: 150,
                                            child: CustomPaint(
                                              painter: _PieChartPainter(
                                                  topCategories
                                                      .map((entry) =>
                                                          entry.value)
                                                      .toList()),
                                              child: const SizedBox.expand(),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                for (var i = 0;
                                                    i < topCategories.length;
                                                    i++)
                                                  Padding(
                                                    padding: const EdgeInsets
                                                        .symmetric(vertical: 5),
                                                    child: Row(
                                                      children: [
                                                        CircleAvatar(
                                                          radius: 5,
                                                          backgroundColor:
                                                              _chartColor(i),
                                                        ),
                                                        const SizedBox(
                                                            width: 8),
                                                        Expanded(
                                                          child: Text(
                                                            topCategories[i]
                                                                .key,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .bodySmall,
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                            width: 6),
                                                        Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .end,
                                                          children: [
                                                            Text(
                                                              formatCurrency(
                                                                  topCategories[
                                                                          i]
                                                                      .value),
                                                              style: Theme.of(
                                                                      context)
                                                                  .textTheme
                                                                  .labelSmall
                                                                  ?.copyWith(
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w700),
                                                            ),
                                                            Text(
                                                              '${(topCategories[i].value / totalExpenses * 100).toStringAsFixed(1)}%',
                                                              style: Theme.of(
                                                                      context)
                                                                  .textTheme
                                                                  .labelSmall
                                                                  ?.copyWith(
                                                                    color: Theme.of(
                                                                            context)
                                                                        .colorScheme
                                                                        .onSurfaceVariant,
                                                                  ),
                                                            ),
                                                          ],
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                            ),
                          ),
                          SizedBox(
                            width: panelWidth,
                            child: _DashboardPanel(
                              title: 'Income by source',
                              icon: Icons.account_balance_wallet_outlined,
                              child: topIncomeSources.isEmpty
                                  ? const _InlineEmpty(
                                      message:
                                          'No income sources recorded yet.')
                                  : Column(
                                      children: [
                                        for (final entry
                                            in topIncomeSources.take(5))
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 6),
                                            child: _ComparisonBar(
                                              label: entry.key,
                                              amount: entry.value,
                                              fraction: entry.value /
                                                  topIncomeSources.first.value,
                                              color: const Color(0xFF38B89A),
                                            ),
                                          ),
                                      ],
                                    ),
                            ),
                          ),
                          SizedBox(
                            width: panelWidth,
                            child: _DashboardPanel(
                              title: 'Monthly spending trend',
                              icon: Icons.bar_chart_rounded,
                              child: monthlyRows.isEmpty
                                  ? const _InlineEmpty(
                                      message:
                                          'No monthly expense data in this period.')
                                  : SizedBox(
                                      height: 176,
                                      child: CustomPaint(
                                        painter: _MonthlyBarPainter([
                                          for (final row in monthlyRows)
                                            {
                                              'month': row.key,
                                              'total': row.value,
                                            },
                                        ]),
                                        child: const SizedBox.expand(),
                                      ),
                                    ),
                            ),
                          ),
                          SizedBox(
                            width: panelWidth,
                            child: _DashboardPanel(
                              title: 'Income vs expenses',
                              icon: Icons.compare_arrows_rounded,
                              child: _IncomeExpenseComparison(
                                income: totalIncome,
                                expenses: totalExpenses,
                              ),
                            ),
                          ),
                          if (topCategories.isNotEmpty ||
                              highestExpense != null)
                            SizedBox(
                              width: width,
                              child: _DashboardPanel(
                                title: 'Period highlights',
                                icon: Icons.auto_awesome_outlined,
                                child: Wrap(
                                  spacing: 24,
                                  runSpacing: 12,
                                  children: [
                                    if (topCategories.isNotEmpty)
                                      _HighlightValue(
                                        label: 'Top expense category',
                                        value: topCategories.first.key,
                                      ),
                                    if (highestExpense != null)
                                      _HighlightValue(
                                        label: 'Largest expense',
                                        value:
                                            '${formatCurrency(highestExpense.amount)} · ${highestExpense.merchant.isNotEmpty ? highestExpense.merchant : highestExpense.category}',
                                      ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _periodChip(AnalyticsPeriod period, String label) => ChoiceChip(
        label: Text(label),
        selected: _period == period,
        onSelected: (_) => setState(() => _period = period),
      );
}

String _analyticsDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/'
    '${date.month.toString().padLeft(2, '0')}/${date.year}';

class _AnalyticsEmptyState extends StatelessWidget {
  const _AnalyticsEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.outlineVariant.withOpacity(.55)),
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(Icons.insights_outlined, color: colors.primary),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('No spending data yet',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                SizedBox(height: 4),
                Text('Add transactions to see your financial analytics.'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IncomeExpenseComparison extends StatelessWidget {
  const _IncomeExpenseComparison({
    required this.income,
    required this.expenses,
  });

  final double income;
  final double expenses;

  @override
  Widget build(BuildContext context) {
    final maxValue = math.max(income, expenses);
    return Column(
      children: [
        _ComparisonBar(
          label: 'Income',
          amount: income,
          fraction: maxValue <= 0 ? 0 : income / maxValue,
          color: const Color(0xFF38B89A),
        ),
        const SizedBox(height: 14),
        _ComparisonBar(
          label: 'Expenses',
          amount: expenses,
          fraction: maxValue <= 0 ? 0 : expenses / maxValue,
          color: const Color(0xFFE77872),
        ),
      ],
    );
  }
}

class _ComparisonBar extends StatelessWidget {
  const _ComparisonBar({
    required this.label,
    required this.amount,
    required this.fraction,
    required this.color,
  });

  final String label;
  final double amount;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
                child:
                    Text(label, style: Theme.of(context).textTheme.bodySmall)),
            Text(formatCurrency(amount),
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 8,
            color: color,
            backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _HighlightValue extends StatelessWidget {
  const _HighlightValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 4),
        Text(value,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
      ],
    );
  }
}

Color _chartColor(int index) {
  const colors = [
    Color(0xFF2673E8),
    Color(0xFF21A58A),
    Color(0xFFFF9F43),
    Color(0xFFE85D75),
    Color(0xFF8B65D8),
    Color(0xFF48A9C5),
    Color(0xFFB8A342),
    Color(0xFF5B7184),
  ];
  return colors[index % colors.length];
}

class _PieChartPainter extends CustomPainter {
  _PieChartPainter(this.values);

  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<double>(0, (sum, value) => sum + value);
    if (total <= 0) return;
    final diameter = size.shortestSide * 0.88;
    final rect = Rect.fromCenter(
        center: size.center(Offset.zero), width: diameter, height: diameter);
    var start = -math.pi / 2;
    for (var index = 0; index < values.length; index++) {
      final sweep = values[index] / total * math.pi * 2;
      canvas.drawArc(
          rect, start, sweep, true, Paint()..color = _chartColor(index));
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _PieChartPainter oldDelegate) =>
      oldDelegate.values != values;
}

class _MonthlyBarPainter extends CustomPainter {
  _MonthlyBarPainter(this.rows);

  final List<Map<String, dynamic>> rows;

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty) return;
    const bottom = 28.0;
    const top = 12.0;
    final values =
        rows.map((row) => (row['total'] as num?)?.toDouble() ?? 0).toList();
    final maxValue = values.fold<double>(0, math.max);
    if (maxValue <= 0) return;
    final usableHeight = size.height - bottom - top;
    final slotWidth = size.width / rows.length;
    for (var index = 0; index < rows.length; index++) {
      final height = usableHeight * values[index] / maxValue;
      final rect = Rect.fromLTWH(index * slotWidth + slotWidth * 0.2,
          top + usableHeight - height, slotWidth * 0.6, height);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6)),
          Paint()..color = _chartColor(index));
      final month = (rows[index]['month'] ?? '').toString().split('-').last;
      final text = TextPainter(
        text: TextSpan(
            text: month,
            style: const TextStyle(fontSize: 10, color: Colors.grey)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: slotWidth);
      text.paint(
          canvas,
          Offset(index * slotWidth + (slotWidth - text.width) / 2,
              size.height - 18));
    }
  }

  @override
  bool shouldRepaint(covariant _MonthlyBarPainter oldDelegate) =>
      oldDelegate.rows != rows;
}

class ProfileView extends StatefulWidget {
  const ProfileView({
    super.key,
    required this.user,
    required this.prefs,
    required this.onLogout,
    required this.themeMode,
    required this.onThemeChanged,
    required this.onDataChanged,
    required this.transactions,
    required this.categories,
  });

  final AppUser user;
  final SharedPreferences prefs;
  final VoidCallback onLogout;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final Future<void> Function() onDataChanged;
  final List<TransactionRecord> transactions;
  final List<CategoryRecord> categories;

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  late String _displayName;
  late bool _notificationsEnabled;
  late bool _smsScanningEnabled;
  late bool _aiEnabled;

  static const _profileNameKey = 'trackyo_profile_display_name';
  static const _localTransactionCacheKey = 'trackyo_local_transactions';

  @override
  void initState() {
    super.initState();
    _displayName =
        widget.prefs.getString(_profileNameKey) ?? widget.user.fullName;
    _notificationsEnabled =
        widget.prefs.getBool('trackyo_notifications_enabled') ?? true;
    _smsScanningEnabled =
        widget.prefs.getBool('trackyo_sms_scanning_enabled') ?? true;
    _aiEnabled = widget.prefs.getBool('trackyo_ai_enabled') ?? true;
  }

  String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty);
    if (parts.isEmpty) return 'T';
    return parts.take(2).map((part) => part[0].toUpperCase()).join();
  }

  Future<void> _editProfile() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _EditProfileDialog(initialName: _displayName),
    );
    if (name == null || !mounted) return;
    await widget.prefs.setString(_profileNameKey, name);
    if (mounted) setState(() => _displayName = name);
  }

  Future<void> _setPreference(String key, bool value) async {
    await widget.prefs.setBool(key, value);
    if (!mounted) return;
    setState(() {
      if (key == 'trackyo_notifications_enabled') {
        _notificationsEnabled = value;
      } else if (key == 'trackyo_sms_scanning_enabled') {
        _smsScanningEnabled = value;
      } else {
        _aiEnabled = value;
      }
    });
  }

  Future<void> _chooseDefault(String key, String title, List<String> options,
      String currentValue) async {
    if (options.isEmpty) {
      _showProfileMessage('No options are available yet.');
      return;
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            for (final option in options)
              RadioListTile<String>(
                value: option,
                groupValue: currentValue,
                title: Text(option),
                onChanged: (value) => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
    if (selected != null) await widget.prefs.setString(key, selected);
    if (selected != null && mounted) setState(() {});
  }

  void _showProfileMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showProfileInformation() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Profile information'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Name\n$_displayName'),
            const SizedBox(height: 14),
            Text('Email\n${widget.user.email}'),
            const SizedBox(height: 14),
            const Text('Currency\nIndian Rupee (₹)'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _clearLocalTransactionData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear local transaction data?'),
        content: const Text(
          'This only clears transaction data stored on this device. '
          'Transactions in your TrackYo account will not be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear local data'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final hadLocalCache = widget.prefs.containsKey(_localTransactionCacheKey);
    await widget.prefs.remove(_localTransactionCacheKey);
    if (mounted) {
      _showProfileMessage(hadLocalCache
          ? 'Local transaction data cleared. Account transactions are unchanged.'
          : 'No local transaction cache was present. Account transactions are unchanged.');
    }
  }

  String _csvField(Object? value) {
    final text = (value ?? '').toString();
    return '"${text.replaceAll('"', '""')}"';
  }

  Future<void> _exportCsv() async {
    try {
      final transactions = widget.transactions;
      final rows = <List<Object?>>[
        [
          'Date',
          'Type',
          'Amount',
          'Category',
          'Income source',
          'Merchant',
          'Payment method',
          'Description',
          'Entry source'
        ],
        ...transactions.map((transaction) => [
              transaction.date.toIso8601String().split('T').first,
              transaction.type.name,
              transaction.amount.toStringAsFixed(2),
              transaction.category,
              transaction.incomeSource,
              transaction.merchant,
              transaction.paymentMethod,
              transaction.description,
              transaction.source,
            ]),
      ];
      final csv = rows.map((row) => row.map(_csvField).join(',')).join('\r\n');
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Export transactions'),
          content: Text(
            transactions.isEmpty
                ? 'There are no transactions to export yet.'
                : '${transactions.length} transactions are ready as CSV. '
                    'Copy the CSV to paste it into a spreadsheet or save it as a .csv file.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
            if (transactions.isNotEmpty)
              FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: csv));
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  if (mounted) _showProfileMessage('CSV copied to clipboard.');
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy CSV'),
              ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) _showProfileMessage('Could not export transactions: $error');
    }
  }

  Future<void> _showInformation(String title, String message) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log out of TrackYo?'),
        content: const Text(
            'Your account data will remain saved. You can log in again anytime.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Profile'),
            Text('Make TrackYo work for you',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: colors.onSurfaceVariant)),
          ],
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          final width =
              math.max(0.0, math.min(constraints.maxWidth - 36.0, 880.0));
          return SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 36),
            child: Center(
              child: SizedBox(
                width: width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: colors.outlineVariant.withOpacity(.55)),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 30,
                            backgroundColor: colors.primaryContainer,
                            child: Text(
                              _initials(_displayName),
                              style: TextStyle(
                                  color: colors.primary,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800),
                            ),
                          ),
                          const SizedBox(width: 15),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_displayName,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(
                                            fontWeight: FontWeight.w800)),
                                const SizedBox(height: 3),
                                Text(widget.user.email,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                            color: colors.onSurfaceVariant)),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Edit profile',
                            onPressed: _editProfile,
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          if (width >= 600)
                            Icon(Icons.verified_user_outlined,
                                color: colors.primary),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    const _SectionTitle(title: 'Account'),
                    const SizedBox(height: 9),
                    Card(
                      child: Column(
                        children: [
                          ListTile(
                            leading: const _SettingsIcon(
                                icon: Icons.person_outline_rounded),
                            title: const Text('Profile information'),
                            subtitle: Text(widget.user.email,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: _showProfileInformation,
                          ),
                          const Divider(height: 1, indent: 64),
                          const ListTile(
                            leading: _SettingsIcon(
                                icon: Icons.currency_rupee_rounded),
                            title: Text('Currency'),
                            subtitle: Text('Indian Rupee'),
                            trailing: Text('₹ INR'),
                          ),
                          const Divider(height: 1, indent: 64),
                          Builder(builder: (context) {
                            const methods = [
                              'UPI',
                              'Cash',
                              'Card',
                              'Bank Transfer'
                            ];
                            final selected = widget.prefs.getString(
                                    'trackyo_default_payment_method') ??
                                'UPI';
                            return ListTile(
                              leading: const _SettingsIcon(
                                  icon: Icons.payments_outlined),
                              title: const Text('Default payment method'),
                              subtitle: Text(selected),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => _chooseDefault(
                                'trackyo_default_payment_method',
                                'Default payment method',
                                methods,
                                selected,
                              ),
                            );
                          }),
                          const Divider(height: 1, indent: 64),
                          Builder(builder: (context) {
                            final options = widget.categories
                                .map((category) => category.name)
                                .toList();
                            final selected = widget.prefs.getString(
                                    'trackyo_default_transaction_category') ??
                                (options.contains('Other')
                                    ? 'Other'
                                    : (options.isEmpty
                                        ? 'Other'
                                        : options.first));
                            return ListTile(
                              leading: const _SettingsIcon(
                                  icon: Icons.category_outlined),
                              title: const Text('Default transaction category'),
                              subtitle: Text(selected,
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => _chooseDefault(
                                'trackyo_default_transaction_category',
                                'Default transaction category',
                                options,
                                selected,
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _SectionTitle(title: 'App settings'),
                    const SizedBox(height: 9),
                    Card(
                      child: Column(
                        children: [
                          SwitchListTile(
                            secondary: const _SettingsIcon(
                                icon: Icons.palette_outlined),
                            title: const Text('Dark mode'),
                            subtitle: Text(widget.themeMode == ThemeMode.dark
                                ? 'Dark appearance enabled'
                                : 'Light appearance enabled'),
                            value: widget.themeMode == ThemeMode.dark,
                            onChanged: (value) => widget.onThemeChanged(
                                value ? ThemeMode.dark : ThemeMode.light),
                          ),
                          const Divider(height: 1, indent: 64),
                          SwitchListTile(
                            secondary: const _SettingsIcon(
                                icon: Icons.notifications_outlined),
                            title: const Text('Notifications'),
                            subtitle:
                                const Text('Save your notification preference'),
                            value: _notificationsEnabled,
                            onChanged: (value) => _setPreference(
                                'trackyo_notifications_enabled', value),
                          ),
                          const Divider(height: 1, indent: 64),
                          SwitchListTile(
                            secondary:
                                const _SettingsIcon(icon: Icons.sms_outlined),
                            title: const Text('SMS transaction scanning'),
                            subtitle: const Text(
                                'SMS is processed on-device for transaction detection'),
                            value: _smsScanningEnabled,
                            onChanged: (value) => _setPreference(
                                'trackyo_sms_scanning_enabled', value),
                          ),
                          const Divider(height: 1, indent: 64),
                          ListTile(
                            leading: const _SettingsIcon(
                                icon: Icons.document_scanner_outlined),
                            title: const Text('Receipt scanning'),
                            subtitle: const Text(
                                'Scan receipts when adding an expense'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => _showInformation(
                              'Receipt scanning',
                              'Choose Scan receipt from Add Expense. '
                                  'Receipt text is extracted on this device and '
                                  'you can review it before saving.',
                            ),
                          ),
                          const Divider(height: 1, indent: 64),
                          SwitchListTile(
                            secondary: const _SettingsIcon(
                                icon: Icons.auto_awesome_outlined),
                            title: const Text('AI assistant'),
                            subtitle: const Text(
                                'Save your assistant preference on this device'),
                            value: _aiEnabled,
                            onChanged: (value) =>
                                _setPreference('trackyo_ai_enabled', value),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _SectionTitle(title: 'Manage your money'),
                    const SizedBox(height: 9),
                    Card(
                      child: Column(
                        children: [
                          ListTile(
                            leading: const _SettingsIcon(
                                icon: Icons.category_outlined),
                            title: const Text('Categories'),
                            subtitle: const Text('Organize your transactions'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () async {
                              await Navigator.of(context)
                                  .push(MaterialPageRoute<void>(
                                builder: (_) => CategoryManagementScreen(
                                    prefs: widget.prefs),
                              ));
                              if (context.mounted) {
                                await widget.onDataChanged();
                              }
                            },
                          ),
                          const Divider(height: 1, indent: 64),
                          ListTile(
                            leading: const _SettingsIcon(
                                icon: Icons.savings_outlined),
                            title: const Text('Budgets'),
                            subtitle:
                                const Text('Set limits and track progress'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () async {
                              await Navigator.of(context)
                                  .push(MaterialPageRoute<void>(
                                builder: (_) =>
                                    BudgetManagementScreen(prefs: widget.prefs),
                              ));
                              if (context.mounted) {
                                await widget.onDataChanged();
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _SectionTitle(title: 'Privacy & security'),
                    const SizedBox(height: 9),
                    Card(
                      child: Column(
                        children: [
                          ListTile(
                            leading: const _SettingsIcon(
                                icon: Icons.privacy_tip_outlined),
                            title: const Text('Your financial privacy'),
                            subtitle: const Text(
                              'SMS content is processed only to detect transaction details. '
                              'Messages are not uploaded as an inbox.',
                            ),
                            isThreeLine: true,
                            onTap: () => _showInformation(
                              'Privacy information',
                              'TrackYo requests SMS access only when you start SMS Scan. '
                                  'Messages are processed locally for transaction detection; '
                                  'only transactions you review and save are sent to your account. '
                                  'Receipt OCR is also performed on-device.',
                            ),
                          ),
                          const Divider(height: 1, indent: 64),
                          ListTile(
                            leading: const _SettingsIcon(
                                icon: Icons.delete_outline_rounded),
                            title: const Text('Clear local transaction data'),
                            subtitle: const Text(
                                'Does not delete transactions in your account'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: _clearLocalTransactionData,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _SectionTitle(title: 'Data management'),
                    const SizedBox(height: 9),
                    Card(
                      child: Column(
                        children: [
                          ListTile(
                            leading: const _SettingsIcon(
                                icon: Icons.file_download_outlined),
                            title: const Text('Export transactions as CSV'),
                            subtitle: const Text(
                                'Copy your saved transactions for a spreadsheet'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: _exportCsv,
                          ),
                          const Divider(height: 1, indent: 64),
                          const ListTile(
                            leading:
                                _SettingsIcon(icon: Icons.file_upload_outlined),
                            title: Text('Import transactions'),
                            subtitle:
                                Text('Import is not available in this version'),
                            enabled: false,
                          ),
                          const Divider(height: 1, indent: 64),
                          const ListTile(
                            leading:
                                _SettingsIcon(icon: Icons.cloud_sync_outlined),
                            title: Text('Backup & Restore'),
                            subtitle: Text('No backup service is configured'),
                            enabled: false,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _SectionTitle(title: 'About'),
                    const SizedBox(height: 9),
                    Card(
                      child: Column(
                        children: [
                          const ListTile(
                            leading: _SettingsIcon(
                                icon: Icons.account_balance_wallet_rounded),
                            title: Text('TrackYo'),
                            subtitle: Text('Version 1.0.0+1'),
                          ),
                          const Divider(height: 1, indent: 64),
                          ListTile(
                            leading: const _SettingsIcon(
                                icon: Icons.info_outline_rounded),
                            title: const Text('About TrackYo'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => _showInformation(
                              'About TrackYo',
                              'TrackYo helps you record transactions, manage budgets, '
                                  'and understand your spending.',
                            ),
                          ),
                          const Divider(height: 1, indent: 64),
                          ListTile(
                            leading: const _SettingsIcon(
                                icon: Icons.description_outlined),
                            title: const Text('Terms of use'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => _showInformation('Terms of use',
                                'Terms of use are not available in this version.'),
                          ),
                          const Divider(height: 1, indent: 64),
                          ListTile(
                            leading: const _SettingsIcon(
                                icon: Icons.policy_outlined),
                            title: const Text('Privacy policy'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => _showInformation('Privacy policy',
                                'The privacy policy is not available in this version.'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _SectionTitle(title: 'Your assistant'),
                    const SizedBox(height: 9),
                    Card(
                      child: ListTile(
                        leading: const _SettingsIcon(
                            icon: Icons.auto_awesome_rounded),
                        title: const Text('TrackYo AI'),
                        subtitle:
                            const Text('Explore insights from your activity'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _aiEnabled
                            ? () => Navigator.of(context)
                                    .push(MaterialPageRoute<void>(
                                  builder: (_) =>
                                      AiChatScreen(prefs: widget.prefs),
                                ))
                            : null,
                      ),
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _confirmLogout,
                        icon: const Icon(Icons.logout_rounded),
                        label: const Text('Log out'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colors.error,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: BorderSide(color: colors.error.withOpacity(.4)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Center(
                      child: Text(
                          'TrackYo · Track your money. Own your future.',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: colors.onSurfaceVariant)),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _EditProfileDialog extends StatefulWidget {
  const _EditProfileDialog({required this.initialName});

  final String initialName;

  @override
  State<_EditProfileDialog> createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends State<_EditProfileDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit profile'),
      scrollable: true,
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        maxLength: 60,
        decoration: const InputDecoration(
          labelText: 'Name',
          hintText: 'Your name',
          helperText: 'This display name is saved on this device.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final value = _controller.text.trim();
            if (value.isEmpty) return;
            Navigator.pop(context, value);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _SettingsIcon extends StatelessWidget {
  const _SettingsIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(12)),
      child: Icon(icon, color: colors.primary, size: 20),
    );
  }
}

class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key, required this.prefs});

  final SharedPreferences prefs;

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [
    const _ChatMessage(
      text:
          'Ask about your spending, top category, biggest expense, budget remaining, or income vs expenses.',
      isUser: false,
    ),
  ];
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send([String? prompt]) async {
    final question = (prompt ?? _controller.text).trim();
    if (question.isEmpty || _sending) return;
    _controller.clear();
    setState(() {
      _sending = true;
      _messages.add(_ChatMessage(text: question, isUser: true));
    });
    try {
      final answer = await ApiService.askAi(widget.prefs, question);
      if (!mounted) return;
      setState(() => _messages.add(_ChatMessage(text: answer, isUser: false)));
    } catch (error) {
      if (!mounted) return;
      setState(() => _messages.add(_ChatMessage(
          text: 'I could not reach the finance service. $error',
          isUser: false)));
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (_scrollController.hasClients) {
          await _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const prompts = [
      'How much did I spend this month?',
      'Where did I spend the most?',
      'How much budget is remaining?',
      'Compare this month with last month.',
      'What is my biggest expense?',
      'Which category should I reduce?',
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('TrackYo AI')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Material(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.privacy_tip_outlined,
                        size: 20,
                        color:
                            Theme.of(context).colorScheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Answers are calculated on your TrackYo backend from your saved transactions and budgets. Financial data is not sent to an external AI service.',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSecondaryContainer,
                                  ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  return Align(
                    alignment: message.isUser
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      constraints: BoxConstraints(
                          maxWidth: MediaQuery.sizeOf(context).width * 0.82),
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: message.isUser
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        message.text,
                        style: TextStyle(
                            color: message.isUser
                                ? Theme.of(context).colorScheme.onPrimary
                                : null),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_messages.length <= 1)
              SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final prompt in prompts)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                            label: Text(prompt),
                            onPressed: _sending ? null : () => _send(prompt)),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                          hintText: 'Ask about your finances',
                          border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatMessage {
  const _ChatMessage({required this.text, required this.isUser});

  final String text;
  final bool isUser;
}

class CategoryManagementScreen extends StatefulWidget {
  const CategoryManagementScreen({super.key, required this.prefs});

  final SharedPreferences prefs;

  @override
  State<CategoryManagementScreen> createState() =>
      _CategoryManagementScreenState();
}

class _CategoryManagementScreenState extends State<CategoryManagementScreen> {
  List<CategoryRecord> _categories = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final categories = await ApiService.getCategories(widget.prefs);
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _edit([CategoryRecord? original]) async {
    final nameController = TextEditingController(text: original?.name ?? '');
    final iconController =
        TextEditingController(text: original?.icon ?? 'category');
    final colorController =
        TextEditingController(text: original?.color ?? '#3B82F6');
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<CategoryRecord>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(original == null ? 'Add category' : 'Edit category'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a category name'
                    : null,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextFormField(
                  controller: iconController,
                  decoration: const InputDecoration(labelText: 'Icon name')),
              TextFormField(
                controller: colorController,
                validator: (value) => value != null &&
                        RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)
                    ? null
                    : 'Use a color such as #3B82F6',
                decoration: const InputDecoration(labelText: 'Color (hex)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (!(formKey.currentState?.validate() ?? false)) return;
              Navigator.pop(
                dialogContext,
                CategoryRecord(
                  id: original?.id ?? '',
                  name: nameController.text.trim(),
                  icon: iconController.text.trim().isEmpty
                      ? 'category'
                      : iconController.text.trim(),
                  color: colorController.text.trim(),
                ),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    nameController.dispose();
    iconController.dispose();
    colorController.dispose();
    if (result == null) return;
    try {
      if (original == null) {
        await ApiService.addCategory(
            widget.prefs, result.name, result.icon, result.color);
      } else {
        await ApiService.updateCategory(widget.prefs, result);
      }
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Category saved')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _delete(CategoryRecord category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete category?'),
        content: Text(
            'Delete "${category.name}"? Categories used by transactions cannot be deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ApiService.deleteCategory(widget.prefs, category.id);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Category deleted')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Add category'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: const Text('Retry'))
                ]))
              : _categories.isEmpty
                  ? const Center(
                      child: EmptyState(
                          message:
                              'No categories yet. Create one to organize transactions.'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _categories.length,
                      itemBuilder: (context, index) {
                        final category = _categories[index];
                        return Card(
                          child: ListTile(
                            leading: const CircleAvatar(
                                child: Icon(Icons.category_outlined)),
                            title: Text(category.name),
                            subtitle: Text(
                              category.isDefault
                                  ? 'Default expense category'
                                  : 'Custom expense category',
                            ),
                            trailing: Wrap(
                              children: [
                                if (!category.isDefault) ...[
                                  IconButton(
                                      onPressed: () => _edit(category),
                                      icon: const Icon(Icons.edit_outlined)),
                                  IconButton(
                                      onPressed: () => _delete(category),
                                      icon: const Icon(Icons.delete_outline),
                                      color: Colors.red),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

class BudgetManagementScreen extends StatefulWidget {
  const BudgetManagementScreen({super.key, required this.prefs});

  final SharedPreferences prefs;

  @override
  State<BudgetManagementScreen> createState() => _BudgetManagementScreenState();
}

class _BudgetManagementScreenState extends State<BudgetManagementScreen> {
  List<BudgetRecord> _budgets = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final budgets = await ApiService.getBudgets(widget.prefs);
      if (!mounted) return;
      setState(() {
        _budgets = budgets;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _edit([BudgetRecord? original]) async {
    final result = await showDialog<BudgetRecord>(
      context: context,
      builder: (_) => BudgetEditorDialog(original: original),
    );
    if (result == null) return;
    try {
      if (original == null) {
        await ApiService.addBudget(
            widget.prefs, result.category, result.amount, result.month);
      } else {
        await ApiService.updateBudget(widget.prefs, result);
      }
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Budget saved')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _delete(BudgetRecord budget) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete budget?'),
        content: Text('Delete ${budget.category} budget for ${budget.month}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ApiService.deleteBudget(widget.prefs, budget.id);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Budget deleted')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Monthly budgets')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Add budget'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: const Text('Retry'))
                ]))
              : _budgets.isEmpty
                  ? const Center(
                      child: EmptyState(
                          message:
                              'No budgets yet. Set a category limit to track spending.'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _budgets.length,
                      itemBuilder: (context, index) {
                        final budget = _budgets[index];
                        final exceeded = budget.percentUsed >= 1;
                        final warning = budget.percentUsed >= 0.8;
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                      '${budget.category} • ${budget.month}'),
                                  subtitle: Text(
                                      '${formatCurrency(budget.spent)} of ${formatCurrency(budget.amount)} • ${formatCurrency(budget.remaining)} remaining'),
                                  trailing: Wrap(
                                    children: [
                                      IconButton(
                                          onPressed: () => _edit(budget),
                                          icon:
                                              const Icon(Icons.edit_outlined)),
                                      IconButton(
                                          onPressed: () => _delete(budget),
                                          icon:
                                              const Icon(Icons.delete_outline),
                                          color: Colors.red),
                                    ],
                                  ),
                                ),
                                LinearProgressIndicator(
                                  value: budget.percentUsed.clamp(0.0, 1.0),
                                  color: exceeded
                                      ? Colors.red
                                      : warning
                                          ? Colors.orange
                                          : null,
                                  minHeight: 8,
                                ),
                                if (warning)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                          exceeded
                                              ? 'Limit exceeded'
                                              : '80% of this budget used',
                                          style: TextStyle(
                                              color: exceeded
                                                  ? Colors.red
                                                  : Colors.orange)),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

class BudgetEditorDialog extends StatefulWidget {
  const BudgetEditorDialog({super.key, this.original});

  final BudgetRecord? original;

  @override
  State<BudgetEditorDialog> createState() => _BudgetEditorDialogState();
}

class _BudgetEditorDialogState extends State<BudgetEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _categoryController;
  late final TextEditingController _amountController;
  late final TextEditingController _monthController;

  @override
  void initState() {
    super.initState();
    _categoryController = TextEditingController(
      text: widget.original?.category ?? overallBudgetCategory,
    );
    _amountController = TextEditingController(
      text: widget.original?.amount.toString() ?? '',
    );
    _monthController = TextEditingController(
      text: widget.original?.month ??
          DateTime.now().toIso8601String().substring(0, 7),
    );
  }

  @override
  void dispose() {
    _categoryController.dispose();
    _amountController.dispose();
    _monthController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const fieldPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 19);
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      title:
          Text(widget.original == null ? 'Set monthly budget' : 'Edit budget'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _categoryController,
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a category'
                  : null,
              decoration: const InputDecoration(
                labelText: 'Category',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                contentPadding: fieldPadding,
              ),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _amountController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (value) {
                final amount = double.tryParse(value ?? '');
                return amount == null || amount <= 0
                    ? 'Enter a positive amount'
                    : null;
              },
              decoration: InputDecoration(
                labelText: _categoryController.text == overallBudgetCategory
                    ? 'Monthly spending limit'
                    : 'Monthly category limit',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                contentPadding: fieldPadding,
              ),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _monthController,
              validator: (value) =>
                  value != null && RegExp(r'^\d{4}-\d{2}$').hasMatch(value)
                      ? null
                      : 'Use YYYY-MM',
              decoration: const InputDecoration(
                labelText: 'Month (YYYY-MM)',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                contentPadding: fieldPadding,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!(_formKey.currentState?.validate() ?? false)) return;
            Navigator.pop(
              context,
              BudgetRecord(
                id: widget.original?.id ?? '',
                category: _categoryController.text.trim(),
                amount: double.parse(_amountController.text),
                month: _monthController.text.trim(),
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class TransactionTile extends StatelessWidget {
  const TransactionTile({super.key, required this.transaction, this.trailing});

  final TransactionRecord transaction;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final isExpense = transaction.type == TransactionType.expense;
    final colors = Theme.of(context).colorScheme;
    final color = isExpense ? const Color(0xFFE77872) : const Color(0xFF38B89A);
    final classification = transaction.classificationLabel;
    final icon = _categoryIcon(classification);
    final detail = [
      classification,
      '${transaction.date.day}/${transaction.date.month}/${transaction.date.year}',
      if (transaction.paymentMethod.isNotEmpty) transaction.paymentMethod,
      if (transaction.description.isNotEmpty) transaction.description,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withOpacity(0.13),
              child: Icon(icon, color: color, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isExpense && transaction.merchant.isNotEmpty
                        ? transaction.merchant
                        : classification,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.25,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${isExpense ? '-' : '+'}${formatCurrency(transaction.amount)}',
                  maxLines: 1,
                  style: TextStyle(
                      color: color, fontSize: 14, fontWeight: FontWeight.w800),
                ),
                if (trailing != null) ...[
                  const SizedBox(height: 2),
                  trailing!,
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

IconData _categoryIcon(String category) {
  final name = category.toLowerCase();
  if (name.contains('food') ||
      name.contains('dining') ||
      name.contains('restaurant')) {
    return Icons.restaurant_outlined;
  }
  if (name.contains('transport') ||
      name.contains('travel') ||
      name.contains('fuel')) {
    return Icons.directions_car_outlined;
  }
  if (name.contains('shop')) return Icons.shopping_bag_outlined;
  if (name.contains('home') || name.contains('rent')) {
    return Icons.home_outlined;
  }
  if (name.contains('health') || name.contains('medical')) {
    return Icons.health_and_safety_outlined;
  }
  if (name.contains('salary') || name.contains('income')) {
    return Icons.account_balance_wallet_outlined;
  }
  return Icons.category_outlined;
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.amount,
    required this.icon,
    required this.accent,
  });

  final String title;
  final String amount;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.outlineVariant.withOpacity(.55))),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
                color: accent.withOpacity(.12),
                borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, color: accent, size: 19),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(amount,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: colors.onSurface,
                          fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w800)),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.title,
    this.action,
  });

  final String message;
  final IconData icon;
  final String? title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.outlineVariant.withOpacity(.55)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: colors.primary),
          if (title != null) ...[
            const SizedBox(height: 8),
            Text(title!,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 7),
          Text(message,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant, height: 1.4)),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}

class TrackYoTheme {
  static final ThemeData lightTheme = _createTheme(Brightness.light);
  static final ThemeData darkTheme = _createTheme(Brightness.dark);

  static ThemeData _createTheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF39B99A),
      brightness: brightness,
      surface: dark ? const Color(0xFF172235) : Colors.white,
    ).copyWith(
      primary: dark ? const Color(0xFF78D9BD) : const Color(0xFF16866F),
      onPrimary: dark ? const Color(0xFF06251E) : Colors.white,
      secondary: const Color(0xFF5D91D6),
      error: const Color(0xFFE36F6A),
      surface: dark ? const Color(0xFF172235) : Colors.white,
    );
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(13),
      borderSide: BorderSide(color: scheme.outlineVariant.withOpacity(.75)),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          dark ? const Color(0xFF101827) : const Color(0xFFF4F7F8),
      textTheme: ThemeData(brightness: brightness).textTheme.apply(
            bodyColor: scheme.onSurface,
            displayColor: scheme.onSurface,
          ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
            color: scheme.onSurface, fontSize: 19, fontWeight: FontWeight.w800),
      ),
      cardTheme: CardTheme(
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(17),
          side: BorderSide(color: scheme.outlineVariant.withOpacity(.55)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF1B293C) : const Color(0xFFF8FAFB),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        errorBorder: border.copyWith(
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: border.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        elevation: 4,
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: MaterialStateProperty.resolveWith((states) => TextStyle(
              fontSize: 11,
              fontWeight: states.contains(MaterialState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: states.contains(MaterialState.selected)
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            )),
      ),
      dividerTheme: DividerThemeData(
          color: scheme.outlineVariant.withOpacity(.5), thickness: 1),
    );
  }
}

String formatCurrency(num value) {
  final abs = value.abs();
  final formatted = abs.toStringAsFixed(0).replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
        (Match match) => '${match[1]},',
      );
  return '${value < 0 ? '-' : ''}₹$formatted';
}

bool _isValidEmail(String value) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim());

String _authErrorMessage(Object error) =>
    error.toString().replaceFirst(RegExp(r'^(Exception|Error):\s*'), '');

void _showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
