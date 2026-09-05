class CorrectedAnswerModel {
  CorrectedAnswerModel({
    required this.questionId,
    required this.correctAnswer,
    required this.answerSource,
    required this.confidence,
  });

  final int questionId;
  final String correctAnswer;
  final String answerSource;
  final int? confidence;

  factory CorrectedAnswerModel.fromJson(Map<String, dynamic> json) {
    return CorrectedAnswerModel(
      questionId: json["question_id"] as int,
      correctAnswer: json["correct_answer"] as String? ?? "",
      answerSource: json["answer_source"] as String? ?? "user_corrected",
      confidence: json["confidence"] as int?,
    );
  }
}
