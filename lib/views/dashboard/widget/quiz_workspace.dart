import "package:flutter/material.dart";

import "../../../core/api/models/question_check_result_model.dart";
import "../../../core/api/models/question_item_model.dart";
import "../../../core/api/models/quiz_detail_model.dart";
import "../../../core/api/models/submission_summary_model.dart";
import "question_card.dart";

class QuizWorkspace extends StatelessWidget {
  const QuizWorkspace({
    super.key,
    required this.quiz,
    required this.answers,
    required this.submission,
    required this.questionResults,
    required this.checkingQuestionIds,
    required this.submitting,
    required this.onChange,
    required this.onCheckQuestion,
    required this.onSubmit,
    required this.onCorrectAnswer,
  });

  final QuizDetailModel? quiz;
  final Map<int, String> answers;
  final SubmissionSummaryModel? submission;
  final Map<int, QuestionCheckResultModel> questionResults;
  final Set<int> checkingQuestionIds;
  final bool submitting;
  final void Function(QuestionItemModel question, String value) onChange;
  final Future<void> Function(QuestionItemModel question) onCheckQuestion;
  final Future<void> Function() onSubmit;
  final Future<void> Function(QuestionItemModel question, String value) onCorrectAnswer;

  @override
  Widget build(BuildContext context) {
    if (quiz == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text("Select a quiz to see questions."),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              quiz!.title,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text("${quiz!.courseName} | ${quiz!.questionCount} questions"),
            if (submission != null) ...[
              const SizedBox(height: 16),
              Material(
                color: const Color(0xFFE0F0E3),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Score: ${submission!.score}/${submission!.totalQuestions} (${submission!.percentage.toStringAsFixed(2)}%)",
                      ),
                      const SizedBox(height: 8),
                      for (final result in submission!.results)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            "Q${result.questionNumber} ${result.questionType}: ${result.status} - ${result.explanation}",
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            for (final question in quiz!.questions)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: QuestionCard(
                  question: question,
                  currentAnswer: answers[question.id] ?? "",
                  result: questionResults[question.id],
                  isChecking: checkingQuestionIds.contains(question.id),
                  onChanged: (value) => onChange(question, value),
                  onCheck: () => onCheckQuestion(question),
                  onCorrect: (value) => onCorrectAnswer(question, value),
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: submitting ? null : onSubmit,
                icon: submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.task_alt),
                label: Text(submitting ? "Submitting..." : "Submit All Answers"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
