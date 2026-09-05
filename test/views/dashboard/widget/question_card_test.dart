import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:test_app/core/api/models/question_check_result_model.dart";
import "package:test_app/core/api/models/question_item_model.dart";
import "package:test_app/views/dashboard/widget/question_card.dart";

void main() {
  testWidgets("shows the AI confidence badge and reports corrections", (tester) async {
    String? corrected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuestionCard(
            question: QuestionItemModel(
              id: 1,
              questionType: "SAQ",
              questionNumber: 1,
              questionText: "Explain X",
              options: null,
              answerSource: "ai_inferred",
              confidence: 68,
            ),
            currentAnswer: "my answer",
            result: QuestionCheckResultModel(
              questionId: 1,
              questionNumber: 1,
              questionType: "SAQ",
              questionText: "Explain X",
              studentAnswer: "my answer",
              correctAnswer: "AI guess",
              hasCorrectAnswer: true,
              isCorrect: false,
              status: "incorrect",
              explanation: "not quite",
              answerSource: "ai_inferred",
              confidence: 68,
            ),
            isChecking: false,
            onChanged: (_) {},
            onCheck: () {},
            onCorrect: (value) => corrected = value,
          ),
        ),
      ),
    );

    expect(find.textContaining("68% confidence"), findsOneWidget);

    await tester.tap(find.text("Correct this"));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).last, "Real answer");
    await tester.tap(find.byIcon(Icons.check));
    await tester.pump();

    expect(corrected, "Real answer");
  });

  testWidgets("shows no badge for explicit-solution answers", (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuestionCard(
            question: QuestionItemModel(
              id: 1,
              questionType: "MCQ",
              questionNumber: 1,
              questionText: "Pick one",
              options: const {"a": "A", "b": "B"},
              answerSource: "explicit_solution",
              confidence: null,
            ),
            currentAnswer: "A",
            result: QuestionCheckResultModel(
              questionId: 1,
              questionNumber: 1,
              questionType: "MCQ",
              questionText: "Pick one",
              studentAnswer: "A",
              correctAnswer: "A",
              hasCorrectAnswer: true,
              isCorrect: true,
              status: "correct",
              explanation: "Matched the correct option.",
              answerSource: "explicit_solution",
              confidence: null,
            ),
            isChecking: false,
            onChanged: (_) {},
            onCheck: () {},
            onCorrect: (_) {},
          ),
        ),
      ),
    );

    expect(find.text("Correct this"), findsNothing);
  });
}
