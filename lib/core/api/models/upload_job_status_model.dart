import "quiz_summary_model.dart";
import "upload_job_error_model.dart";

class UploadJobStatusModel {
  UploadJobStatusModel({
    required this.jobId,
    required this.status,
    required this.quizzes,
    required this.errors,
  });

  final String jobId;
  final String status;
  final List<QuizSummaryModel> quizzes;
  final List<UploadJobErrorModel> errors;

  factory UploadJobStatusModel.fromJson(Map<String, dynamic> json) {
    final quizzesJson = json["quizzes"] as List<dynamic>? ?? <dynamic>[];
    final errorsJson = json["errors"] as List<dynamic>? ?? <dynamic>[];
    return UploadJobStatusModel(
      jobId: json["job_id"] as String? ?? "",
      status: json["status"] as String? ?? "processing",
      quizzes: quizzesJson
          .map((item) => QuizSummaryModel.fromJson(item as Map<String, dynamic>))
          .toList(),
      errors: errorsJson
          .map((item) => UploadJobErrorModel.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}
