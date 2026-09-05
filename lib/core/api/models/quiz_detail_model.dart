import "question_item_model.dart";

class QuizDetailModel {
  QuizDetailModel({
    required this.id,
    required this.title,
    required this.courseName,
    required this.questionCount,
    required this.needsAnswerKey,
    required this.questions,
  });

  final int id;
  final String title;
  final String courseName;
  final int questionCount;
  final bool needsAnswerKey;
  final List<QuestionItemModel> questions;

  factory QuizDetailModel.fromJson(Map<String, dynamic> json) {
    final questionsJson = json["questions"] as List<dynamic>? ?? <dynamic>[];
    return QuizDetailModel(
      id: json["id"] as int,
      title: json["title"] as String? ?? "Untitled Quiz",
      courseName: json["course_name"] as String? ?? "Unknown Course",
      questionCount: json["question_count"] as int? ?? 0,
      needsAnswerKey: json["needs_answer_key"] as bool? ?? false,
      questions: questionsJson
          .map((item) => QuestionItemModel.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}
