import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'trackyo_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(TrackYoApp(prefs: prefs));
}
