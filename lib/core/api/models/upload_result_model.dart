import "quiz_summary_model.dart";

class UploadResultModel {
  UploadResultModel({required this.primaryQuizId, this.jobId, this.createdQuizzes = const []});

  final int? primaryQuizId;
  final String? jobId;
  final List<QuizSummaryModel> createdQuizzes;

  factory UploadResultModel.fromJson(Map<String, dynamic> json) {
    if (json.containsKey("job_id")) {
      return UploadResultModel(
        primaryQuizId: null,
        jobId: json["job_id"] as String?,
      );
    }

    if (json.containsKey("id")) {
      return UploadResultModel(primaryQuizId: json["id"] as int);
    }

    final quizzes = json["quizzes"] as List<dynamic>? ?? <dynamic>[];
    if (quizzes.isNotEmpty) {
      final firstQuiz = quizzes.first as Map<String, dynamic>;
      return UploadResultModel(primaryQuizId: firstQuiz["id"] as int);
    }

    throw Exception("Upload completed but no quiz was returned.");
  }
}
