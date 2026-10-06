import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trackyo/trackyo_app.dart';

class _MemoryTokenStore implements AuthTokenStore {
  String? token;

  @override
  Future<void> delete() async => token = null;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String value) async => token = value;
}

void main() {
  late AuthTokenStore originalStore;
  late _MemoryTokenStore tokenStore;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    originalStore = ApiService.tokenStore;
    tokenStore = _MemoryTokenStore();
    ApiService.tokenStore = tokenStore;
    ApiService.onUnauthorized = null;
    ApiService.httpClient = null;
  });

  tearDown(() {
    ApiService.tokenStore = originalStore;
    ApiService.onUnauthorized = null;
    ApiService.httpClient?.close();
    ApiService.httpClient = null;
  });

  testWidgets('login validates email and password without submitting',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin: (_, __) async => calls++,
          onRegister: (_, __, ___, ____) async {},
        ),
      ),
    );

    await tester.tap(find.text('Login'));
    await tester.pumpAndSettle();
    expect(find.text('Email is required'), findsOneWidget);
    expect(find.text('Password must be at least 8 characters'), findsOneWidget);
    expect(calls, 0);

    await tester.enterText(find.byType(TextFormField).first, 'not-an-email');
    await tester.enterText(find.byType(TextFormField).at(1), 'long-password');
    await tester.tap(find.text('Login'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('login submits valid credentials and shows server failures',
      (tester) async {
    var calls = 0;
    final completeLogin = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin: (_, __) async {
            calls++;
            await completeLogin.future;
          },
          onRegister: (_, __, ___, ____) async {},
        ),
      ),
    );
    await tester.enterText(
        find.byType(TextFormField).first, 'user@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'valid-pass-123');
    await tester.tap(find.text('Login'));
    await tester.pump();
    expect(find.text('Logging in...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    completeLogin.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin: (_, __) async => throw Exception('Invalid credentials'),
          onRegister: (_, __, ___, ____) async {},
        ),
      ),
    );
    await tester.enterText(
        find.byType(TextFormField).first, 'user@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'valid-pass-123');
    await tester.tap(find.text('Login'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid credentials'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('signup validates email, password length, and mismatch',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin: (_, __) async {},
          onRegister: (_, __, ___, ____) async => calls++,
        ),
      ),
    );
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'Taylor');
    await tester.enterText(find.byType(TextFormField).at(1), 'bad-email');
    await tester.enterText(find.byType(TextFormField).at(2), 'short');
    await tester.enterText(find.byType(TextFormField).at(3), 'different');
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(find.text('Password must be at least 8 characters'), findsOneWidget);
    expect(find.text('Passwords do not match'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('signup submits matching valid credentials', (tester) async {
    var submittedName = '';
    var submittedEmail = '';
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin: (_, __) async {},
          onRegister: (name, email, _, __) async {
            submittedName = name;
            submittedEmail = email;
          },
        ),
      ),
    );
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Taylor Morgan');
    await tester.enterText(
        find.byType(TextFormField).at(1), 'taylor@example.com');
    await tester.enterText(find.byType(TextFormField).at(2), 'secure-pass-1');
    await tester.enterText(find.byType(TextFormField).at(3), 'secure-pass-1');
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();

    expect(submittedName, 'Taylor Morgan');
    expect(submittedEmail, 'taylor@example.com');
    expect(find.text('Welcome back'), findsOneWidget);
  });

  testWidgets('password visibility toggle works on login and signup',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLogin: (_, __) async {},
          onRegister: (_, __, ___, ____) async {},
        ),
      ),
    );
    EditableText passwordField() => tester.widget<EditableText>(
          find.descendant(
            of: find.byType(TextFormField).at(1),
            matching: find.byType(EditableText),
          ),
        );
    expect(passwordField().obscureText, isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pumpAndSettle();
    expect(passwordField().obscureText, isFalse);
  });

  test('successful API login stores only the token in secure session storage',
      () async {
    ApiService.httpClient = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['email'], 'person@example.com');
      expect(body['password'], 'secure-password');
      return http.Response(
        jsonEncode({
          'token': 'signed-session-token',
          'user': {
            'id': 'user-1',
            'fullName': 'Test Person',
            'email': 'person@example.com',
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', 'https://trackyo.test');

    final user = await ApiService.login(
      prefs,
      email: ' person@example.com ',
      password: 'secure-password',
    );
    expect(user.id, 'user-1');
    expect(await tokenStore.read(), 'signed-session-token');
    expect(prefs.getString('trackyo_token'), isNull);
    expect(prefs.getKeys().where((key) => key.contains('password')), isEmpty);
  });

  test('release API uses the configured HTTPS production backend', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', 'http://192.168.0.2:5000');

    expect(
      ApiService.baseUrl(prefs, release: true),
      'https://trackyo-project1.onrender.com',
    );
    expect(
      ApiService.baseUrl(prefs, release: false),
      'http://192.168.0.2:5000',
    );
  });

  test(
      'production API error messages distinguish connectivity and server errors',
      () async {
    final prefs = await SharedPreferences.getInstance();

    ApiService.httpClient = MockClient((request) async {
      throw http.ClientException('Failed host lookup: backend', request.url);
    });
    await expectLater(
      ApiService.login(
        prefs,
        email: 'person@example.com',
        password: 'secure-password',
      ),
      throwsA(predicate(
          (error) => error.toString().contains('No internet connection'))),
    );

    ApiService.httpClient = MockClient((request) async {
      throw http.ClientException('Connection refused', request.url);
    });
    await expectLater(
      ApiService.login(
        prefs,
        email: 'person@example.com',
        password: 'secure-password',
      ),
      throwsA(predicate((error) =>
          error.toString().contains('TrackYo backend is unavailable'))),
    );

    ApiService.httpClient = MockClient((request) async => http.Response(
          '{"message":"Internal server error"}',
          500,
          headers: {'content-type': 'application/json'},
        ));
    await expectLater(
      ApiService.login(
        prefs,
        email: 'person@example.com',
        password: 'secure-password',
      ),
      throwsA(predicate(
          (error) => error.toString().contains('TrackYo server error (500)'))),
    );

    ApiService.httpClient = MockClient((request) async => http.Response(
          '{"message":"Invalid credentials"}',
          401,
          headers: {'content-type': 'application/json'},
        ));
    await expectLater(
      ApiService.login(
        prefs,
        email: 'person@example.com',
        password: 'secure-password',
      ),
      throwsA(predicate(
          (error) => error.toString().contains('Invalid email or password'))),
    );
  });

  test('legacy token migrates from preferences into secure storage', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('trackyo_token', 'legacy-token');

    final token = await ApiService.readToken(prefs);

    expect(token, 'legacy-token');
    expect(await tokenStore.read(), 'legacy-token');
    expect(prefs.getString('trackyo_token'), isNull);
  });

  test('expired token is removed and triggers authenticated-session logout',
      () async {
    final prefs = await SharedPreferences.getInstance();
    tokenStore.token = 'expired-token';
    ApiService.httpClient = MockClient((request) async {
      expect(request.headers['authorization'], 'Bearer expired-token');
      return http.Response(
        jsonEncode({'message': 'Invalid or expired token'}),
        401,
      );
    });
    var unauthorized = false;
    ApiService.onUnauthorized = () => unauthorized = true;

    final user = await ApiService.getCurrentUser(prefs);

    expect(user, isNull);
    expect(await tokenStore.read(), isNull);
    expect(unauthorized, isTrue);
  });

  testWidgets('startup shows login without a stored session', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(TrackYoApp(prefs: prefs));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();

    expect(find.text('Welcome back'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup validates a secure session before opening dashboard',
      (tester) async {
    var verifiedSession = false;
    ApiService.httpClient = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/auth/me') {
        verifiedSession =
            request.headers['authorization'] == 'Bearer valid-startup-token';
        return http.Response(
          jsonEncode({
            'id': 'user-startup',
            'fullName': 'Session User',
            'email': 'session@example.com',
          }),
          200,
        );
      } else if (path == '/api/transactions' ||
          path == '/api/categories' ||
          path == '/api/income-sources' ||
          path == '/api/budgets' ||
          path == '/api/analytics/monthly') {
        return http.Response('[]', 200);
      } else if (path == '/api/ai/insights') {
        return http.Response(jsonEncode({'insights': []}), 200);
      } else if (path == '/api/analytics/summary') {
        return http.Response(
          jsonEncode({
            'totalIncome': 0,
            'totalExpense': 0,
            'savings': 0,
            'monthlyExpense': 0,
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'message': 'Not found'}), 404);
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', 'https://trackyo.test');
    tokenStore.token = 'valid-startup-token';
    await tester.pumpWidget(TrackYoApp(prefs: prefs));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();

    expect(verifiedSession, isTrue);
    expect(find.textContaining(', Session'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logout requires user confirmation', (tester) async {
    var loggedOut = false;
    tokenStore.token = 'active-session';
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileView(
          user: const AppUser(
              id: 'user', fullName: 'Test User', email: 'test@example.com'),
          prefs: prefs,
          onLogout: () async {
            loggedOut = true;
            await ApiService.tokenStore.delete();
          },
          themeMode: ThemeMode.light,
          onThemeChanged: (_) {},
          onDataChanged: () async {},
          transactions: const [],
          categories: const [],
        ),
      ),
    );

    await tester.ensureVisible(find.text('Log out'));
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    expect(loggedOut, isFalse);
    await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
    await tester.pumpAndSettle();
    expect(loggedOut, isTrue);
    expect(await tokenStore.read(), isNull);
  });
}
