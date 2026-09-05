import "package:flutter_test/flutter_test.dart";
import "package:test_app/core/api/models/question_item_model.dart";

void main() {
  test("parses answer_source and confidence from json", () {
    final question = QuestionItemModel.fromJson({
      "id": 1,
      "question_type": "SAQ",
      "question_number": 1,
      "question_text": "Explain X",
      "options": null,
      "answer_source": "ai_inferred",
      "confidence": 72,
    });

    expect(question.answerSource, "ai_inferred");
    expect(question.confidence, 72);
  });

  test("defaults answer_source to unknown when absent", () {
    final question = QuestionItemModel.fromJson({
      "id": 1,
      "question_type": "SAQ",
      "question_number": 1,
      "question_text": "Explain X",
      "options": null,
    });

    expect(question.answerSource, "unknown");
    expect(question.confidence, isNull);
  });
}
