import "package:flutter/material.dart";

import "../../../core/api/models/question_check_result_model.dart";
import "../../../core/api/models/question_item_model.dart";

class QuestionCard extends StatelessWidget {
  const QuestionCard({
    super.key,
    required this.question,
    required this.currentAnswer,
    required this.result,
    required this.isChecking,
    required this.onChanged,
    required this.onCheck,
  });

  final QuestionItemModel question;
  final String currentAnswer;
  final QuestionCheckResultModel? result;
  final bool isChecking;
  final ValueChanged<String> onChanged;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final borderColor = result == null
        ? const Color(0xFFD7DED3)
        : result!.isCorrect
            ? const Color(0xFF2E7D32)
            : const Color(0xFFC62828);
    final backgroundColor = result == null
        ? Colors.white
        : result!.isCorrect
            ? const Color(0xFFE7F6E9)
            : const Color(0xFFFDEAEA);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "Q${question.questionNumber} [${question.questionType}]",
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (isChecking)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (result != null)
                Icon(
                  result!.isCorrect ? Icons.check_circle : Icons.cancel,
                  color: result!.isCorrect
                      ? const Color(0xFF2E7D32)
                      : const Color(0xFFC62828),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(question.questionText),
          const SizedBox(height: 12),
          if (question.questionType == "MCQ" && question.options != null)
            ...question.options!.entries
                .where((entry) => (entry.value ?? "").trim().isNotEmpty)
                .map(
                  (entry) => RadioListTile<String>(
                    value: entry.key.toUpperCase(),
                    groupValue: currentAnswer.isEmpty ? null : currentAnswer,
                    contentPadding: EdgeInsets.zero,
                    title: Text("${entry.key.toUpperCase()}. ${entry.value}"),
                    onChanged: (value) => onChanged(value ?? ""),
                  ),
                )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  initialValue: currentAnswer,
                  minLines: question.questionType == "SEQ" ? 4 : 2,
                  maxLines: question.questionType == "SEQ" ? 6 : 3,
                  onChanged: onChanged,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: "Enter your answer",
                  ),
                ),
                if (question.questionType == "SAQ") ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: currentAnswer.trim().isEmpty || isChecking
                          ? null
                          : onCheck,
                      icon: const Icon(Icons.rule),
                      label: const Text("Check"),
                    ),
                  ),
                ],
              ],
            ),
          if (result != null) ...[
            const SizedBox(height: 12),
            Text(
              result!.isCorrect ? "Correct" : "Incorrect",
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: result!.isCorrect
                    ? const Color(0xFF2E7D32)
                    : const Color(0xFFC62828),
              ),
            ),
            if (result!.hasCorrectAnswer) ...[
              const SizedBox(height: 4),
              Text("Correct answer: ${result!.correctAnswer}"),
            ],
            const SizedBox(height: 4),
            Text(result!.explanation),
          ],
        ],
      ),
    );
  }
}
