import "package:flutter/material.dart";
import "package:hooks_riverpod/hooks_riverpod.dart";

import "views/dashboard/quiz_dashboard_page.dart";

void main() {
  runApp(const ProviderScope(child: PdfQuizApp()));
}

class PdfQuizApp extends StatelessWidget {
  const PdfQuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0B6E4F),
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: "PDF Quiz System",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF5F1E8),
        useMaterial3: true,
      ),
      home: const QuizDashboardPage(),
    );
  }
}
