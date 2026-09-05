import "package:flutter_test/flutter_test.dart";
import "package:test_app/core/api/models/quiz_summary_model.dart";

void main() {
  test("parses needs_answer_key from json", () {
    final quiz = QuizSummaryModel.fromJson({
      "id": 1,
      "title": "Quiz",
      "course_name": "Course",
      "question_count": 3,
      "needs_answer_key": true,
    });

    expect(quiz.needsAnswerKey, isTrue);
  });

  test("defaults needs_answer_key to false when absent", () {
    final quiz = QuizSummaryModel.fromJson({
      "id": 1,
      "title": "Quiz",
      "course_name": "Course",
      "question_count": 3,
    });

    expect(quiz.needsAnswerKey, isFalse);
  });
}
