import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:test_app/core/api/clients/quiz_client/quiz_client.dart";

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
  test("submitAnswerKeyManual posts question numbers and answers", () async {
    final adapter = _RecordingAdapter({
      "applied": 1,
      "quiz": {
        "id": 5,
        "title": "Quiz",
        "course_name": "Course",
        "question_count": 1,
        "needs_answer_key": false,
        "questions": <dynamic>[],
      },
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final client = QuizClient(dio);

    final quiz = await client.submitAnswerKeyManual(5, [const MapEntry(1, "42")]);

    expect(quiz.needsAnswerKey, isFalse);
    final sentData = adapter.lastRequest!.data as Map<String, dynamic>;
    expect(sentData["answers"], [
      {"question_number": 1, "answer": "42"},
    ]);
  });

  test("correctQuestionAnswer parses the corrected answer response", () async {
    final adapter = _RecordingAdapter({
      "quiz_id": 5,
      "question_id": 9,
      "correct_answer": "Real answer",
      "answer_source": "user_corrected",
      "confidence": null,
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final client = QuizClient(dio);

    final result = await client.correctQuestionAnswer(9, "Real answer");

    expect(result.answerSource, "user_corrected");
    expect(result.correctAnswer, "Real answer");
    expect(result.confidence, isNull);
  });
}
