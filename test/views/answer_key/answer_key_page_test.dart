import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:hooks_riverpod/hooks_riverpod.dart";

import "package:test_app/core/api/models/question_item_model.dart";
import "package:test_app/core/api/models/quiz_detail_model.dart";
import "package:test_app/core/providers.dart";
import "package:test_app/views/answer_key/answer_key_page.dart";

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.responseBody);

  final Map<String, dynamic> responseBody;
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      jsonEncode(responseBody),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets("typed answers are submitted for non-empty fields only", (tester) async {
    final adapter = _RecordingAdapter({
      "applied": 1,
      "quiz": {
        "id": 1,
        "title": "Quiz",
        "course_name": "Course",
        "question_count": 1,
        "needs_answer_key": false,
        "questions": <dynamic>[],
      },
    });
    final dio = Dio()..httpClientAdapter = adapter;

    final quiz = QuizDetailModel(
      id: 1,
      title: "Quiz",
      courseName: "Course",
      questionCount: 1,
      needsAnswerKey: true,
      questions: [
        QuestionItemModel(
          id: 10,
          questionType: "SAQ",
          questionNumber: 1,
          questionText: "Explain X",
          options: null,
          answerSource: "unknown",
          confidence: null,
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [dioProvider.overrideWithValue(dio)],
        child: MaterialApp(home: AnswerKeyPage(quiz: quiz)),
      ),
    );

    await tester.enterText(find.byType(TextFormField).first, "42");
    await tester.tap(find.text("Save answers"));
    await tester.pumpAndSettle();

    final sentData = adapter.lastRequest!.data as Map<String, dynamic>;
    expect(sentData["answers"], [
      {"question_number": 1, "answer": "42"},
    ]);
  });
}
