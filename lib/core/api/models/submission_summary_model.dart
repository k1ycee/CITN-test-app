import "question_check_result_model.dart";

class SubmissionSummaryModel {
  SubmissionSummaryModel({
    required this.score,
    required this.totalQuestions,
    required this.percentage,
    required this.results,
  });

  final int score;
  final int totalQuestions;
  final double percentage;
  final List<QuestionCheckResultModel> results;

  factory SubmissionSummaryModel.fromJson(Map<String, dynamic> json) {
    final summary = json["summary"] as Map<String, dynamic>;
    final resultsJson = json["results"] as List<dynamic>? ?? <dynamic>[];
    return SubmissionSummaryModel(
      score: summary["score"] as int? ?? 0,
      totalQuestions: summary["total_questions"] as int? ?? 0,
      percentage: (summary["percentage"] as num?)?.toDouble() ?? 0,
      results: resultsJson
          .map((item) => QuestionCheckResultModel.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}
