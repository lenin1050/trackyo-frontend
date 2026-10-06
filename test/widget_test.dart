import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trackyo/trackyo_app.dart';

class _TestTokenStore implements AuthTokenStore {
  @override
  Future<void> delete() async {}

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String token) async {}
}

void main() {
  testWidgets('TrackYo shows login after splash', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tokenStore = ApiService.tokenStore;
    ApiService.tokenStore = _TestTokenStore();
    addTearDown(() => ApiService.tokenStore = tokenStore);

    await tester.pumpWidget(TrackYoApp(prefs: prefs));
    await tester.pump(const Duration(milliseconds: 1600));

    expect(find.text('Welcome back'), findsOneWidget);
  });
}
