import 'package:flutter/material.dart';

import 'features/import/import_page.dart';

void main() {
  runApp(const BeadStudioApp());
}

class BeadStudioApp extends StatelessWidget {
  const BeadStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "拼豆图案工作室",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4FA8E8),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: const ImportPage(),
    );
  }
}
