class QuizSummaryModel {
  QuizSummaryModel({
    required this.id,
    required this.title,
    required this.courseName,
    required this.questionCount,
    required this.needsAnswerKey,
  });

  final int id;
  final String title;
  final String courseName;
  final int questionCount;
  final bool needsAnswerKey;

  factory QuizSummaryModel.fromJson(Map<String, dynamic> json) {
    return QuizSummaryModel(
      id: json["id"] as int,
      title: json["title"] as String? ?? "Untitled Quiz",
      courseName: json["course_name"] as String? ?? "Unknown Course",
      questionCount: json["question_count"] as int? ?? 0,
      needsAnswerKey: json["needs_answer_key"] as bool? ?? false,
    );
  }
}
