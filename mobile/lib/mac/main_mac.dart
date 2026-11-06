// Earmark for Mac (build with: flutter build macos -t lib/mac/main_mac.dart).
import 'package:flutter/material.dart';

import 'engine.dart';
import 'mac_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final s = MacState();
  runApp(MacApp(s: s));
  s.start();
}
