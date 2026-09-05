import "package:flutter_test/flutter_test.dart";
import "package:test_app/core/api/models/quiz_summary_model.dart";
import "package:test_app/core/view_models/quiz_vm.dart";

void main() {
  test("returns ids of only the quizzes that need an answer key", () {
    final quizzes = [
      QuizSummaryModel(id: 1, title: "A", courseName: "C", questionCount: 3, needsAnswerKey: true),
      QuizSummaryModel(id: 2, title: "B", courseName: "C", questionCount: 4, needsAnswerKey: false),
      QuizSummaryModel(id: 3, title: "D", courseName: "C", questionCount: 2, needsAnswerKey: true),
    ];

    expect(quizIdsNeedingAnswerKey(quizzes), [1, 3]);
  });

  test("returns an empty list when nothing needs a key", () {
    final quizzes = [
      QuizSummaryModel(id: 1, title: "A", courseName: "C", questionCount: 3, needsAnswerKey: false),
    ];

    expect(quizIdsNeedingAnswerKey(quizzes), isEmpty);
  });
}
