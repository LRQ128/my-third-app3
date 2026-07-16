import 'dart:io';
import 'package:flutter/material.dart';
import 'screens/chat_screen.dart';

/// Intercept DNS at the Dart VM level.
/// The `http` package uses `HttpClient` internally, which honors HttpOverrides.
/// Also fixes SecureSocket DNS if used elsewhere.
class _DnsFix extends HttpOverrides {
  @override
  Future<List<InternetAddress>> lookup(
    String host,
    InternetAddressType type, {
    InternetAddress? errorHost,
  }) async {
    if (host == 'ce.a2ne.com') {
      return [InternetAddress('43.131.228.126')];
    }
    return super.lookup(host, type, errorHost: errorHost);
  }
}

void main() {
  HttpOverrides.global = _DnsFix();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI修图',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6366F1),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF6366F1),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}
