import 'dart:io';
import 'package:flutter/material.dart';
import 'screens/chat_screen.dart';

void main() {
  HttpOverrides.global = _DnsOverride();
  runApp(const MyApp());
}

class _DnsOverride extends HttpOverrides {
  @override
  Future<List<InternetAddress>> lookup(String host, InternetAddressType type) async {
    if (host == 'my-third-app3.zeabur.app') {
      return [InternetAddress('43.131.228.126')];
    }
    return super.lookup(host, type);
  }
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
