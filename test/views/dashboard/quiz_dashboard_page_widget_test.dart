import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:file_selector_platform_interface/file_selector_platform_interface.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:hooks_riverpod/hooks_riverpod.dart";

import "package:test_app/core/providers.dart";
import "package:test_app/views/answer_key/answer_key_page.dart";
import "package:test_app/views/dashboard/quiz_dashboard_page.dart";

/// Fake HttpClientAdapter that simulates the backend for the upload ->
/// async job -> gap-fill flow: uploading a PDF produces a job id, the job
/// completes immediately with a quiz that needs an answer key, and every
/// subsequent lookup of that quiz returns the same detail payload.
class _FakeQuizBackendAdapter implements HttpClientAdapter {
  static const _courseJson = <String, dynamic>{
    "id": 1,
    "name": "Course",
    "quiz_count": 1,
  };

  static const _quizSummaryJson = <String, dynamic>{
    "id": 42,
    "title": "Quiz A",
    "course_name": "Course",
    "question_count": 1,
    "needs_answer_key": true,
  };

  static const _quizDetailJson = <String, dynamic>{
    "id": 42,
    "title": "Quiz A",
    "course_name": "Course",
    "question_count": 1,
    "needs_answer_key": true,
    "questions": <dynamic>[
      {
        "id": 100,
        "question_type": "SAQ",
        "question_number": 1,
        "question_text": "What is 2 + 2?",
        "options": null,
        "answer_source": "unknown",
        "confidence": null,
      },
    ],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.path;

    if (path == "/courses") {
      return _jsonResponse(<dynamic>[_courseJson]);
    }
    if (path == "/quizzes") {
      return _jsonResponse(<dynamic>[_quizSummaryJson]);
    }
    if (path == "/quizzes/42") {
      return _jsonResponse(_quizDetailJson);
    }
    if (path == "/upload" && options.method == "POST") {
      return _jsonResponse(<String, dynamic>{"job_id": "job-1"});
    }
    if (path == "/uploads/job-1") {
      return _jsonResponse(<String, dynamic>{
        "job_id": "job-1",
        "status": "completed",
        "quizzes": <dynamic>[_quizSummaryJson],
        "errors": <dynamic>[],
      });
    }

    throw Exception("Unexpected request in fake adapter: ${options.method} $path");
  }

  ResponseBody _jsonResponse(Object data) {
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Fake file picker that always "picks" the same in-memory PDF, so
/// `QuizViewModel.upload()` can be driven without a real platform channel.
class _FakeFileSelectorPlatform extends FileSelectorPlatform {
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    return XFile.fromData(
      Uint8List.fromList(<int>[1, 2, 3]),
      name: "quiz.pdf",
      mimeType: "application/pdf",
    );
  }
}

void main() {
  final originalFileSelector = FileSelectorPlatform.instance;

  setUp(() {
    FileSelectorPlatform.instance = _FakeFileSelectorPlatform();
  });

  tearDown(() {
    FileSelectorPlatform.instance = originalFileSelector;
  });

  testWidgets(
    "navigates to AnswerKeyPage after an upload leaves an answer-key gap",
    (WidgetTester tester) async {
      final dio = Dio()..httpClientAdapter = _FakeQuizBackendAdapter();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [dioProvider.overrideWithValue(dio)],
          child: const MaterialApp(home: QuizDashboardPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AnswerKeyPage), findsNothing);

      await tester.tap(find.text("Upload PDF"));
      await tester.pumpAndSettle();

      expect(find.byType(AnswerKeyPage), findsOneWidget);
    },
  );
}
