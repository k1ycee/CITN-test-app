class QuestionCheckResultModel {
  QuestionCheckResultModel({
    required this.questionId,
    required this.questionNumber,
    required this.questionType,
    required this.questionText,
    required this.studentAnswer,
    required this.correctAnswer,
    required this.hasCorrectAnswer,
    required this.isCorrect,
    required this.status,
    required this.explanation,
  });

  final int questionId;
  final int questionNumber;
  final String questionType;
  final String questionText;
  final String studentAnswer;
  final String correctAnswer;
  final bool hasCorrectAnswer;
  final bool isCorrect;
  final String status;
  final String explanation;

  factory QuestionCheckResultModel.fromJson(Map<String, dynamic> json) {
    return QuestionCheckResultModel(
      questionId: json["question_id"] as int? ?? 0,
      questionNumber: json["question_number"] as int? ?? 0,
      questionType: json["question_type"] as String? ?? "SAQ",
      questionText: json["question_text"] as String? ?? "",
      studentAnswer: json["student_answer"] as String? ?? "",
      correctAnswer: json["correct_answer"] as String? ?? "",
      hasCorrectAnswer: json["has_correct_answer"] as bool? ?? false,
      isCorrect: json["is_correct"] as bool? ?? false,
      status: json["status"] as String? ?? "incorrect",
      explanation: json["explanation"] as String? ?? "",
    );
  }
}
