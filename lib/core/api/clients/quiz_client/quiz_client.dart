import "package:dio/dio.dart";

import "../../models/corrected_answer_model.dart";
import "../../models/course_summary_model.dart";
import "../../models/question_check_result_model.dart";
import "../../models/quiz_detail_model.dart";
import "../../models/quiz_summary_model.dart";
import "../../models/submission_summary_model.dart";
import "../../models/submitted_answer_model.dart";
import "../../models/upload_job_status_model.dart";
import "../../models/upload_result_model.dart";
import "../../urls/quiz_urls.dart";

/// Thin Dio wrapper around the quiz endpoints. Throws on failure; the
/// repository layer is responsible for translating errors.
class QuizClient {
  QuizClient(this._dio);

  final Dio _dio;

  Future<List<CourseSummaryModel>> fetchCourses() async {
    final response = await _dio.get<List<dynamic>>(QuizUrls.courses);
    return (response.data ?? const <dynamic>[])
        .map((item) => CourseSummaryModel.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<QuizSummaryModel>> fetchQuizzes() async {
    final response = await _dio.get<List<dynamic>>(QuizUrls.quizzes);
    return (response.data ?? const <dynamic>[])
        .map((item) => QuizSummaryModel.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<QuizDetailModel> fetchQuiz(int quizId) async {
    final response = await _dio.get<Map<String, dynamic>>(QuizUrls.quiz(quizId));
    return QuizDetailModel.fromJson(response.data!);
  }

  Future<UploadResultModel> uploadPdf(String filename, List<int> bytes) async {
    final formData = FormData.fromMap(<String, dynamic>{
      "async": "true",
      "file": MultipartFile.fromBytes(bytes, filename: filename),
    });
    final response = await _dio.post<Map<String, dynamic>>(QuizUrls.upload, data: formData);
    return UploadResultModel.fromJson(response.data!);
  }

  Future<UploadJobStatusModel> fetchUploadJob(String jobId) async {
    final response = await _dio.get<Map<String, dynamic>>(QuizUrls.uploadJob(jobId));
    return UploadJobStatusModel.fromJson(response.data!);
  }

  Future<SubmissionSummaryModel> submitQuiz(
    int quizId,
    List<SubmittedAnswerModel> answers,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      QuizUrls.submitQuiz(quizId),
      data: <String, dynamic>{
        "answers": answers.map((answer) => answer.toJson()).toList(),
      },
    );
    return SubmissionSummaryModel.fromJson(response.data!);
  }

  Future<QuestionCheckResultModel> submitQuestion(int questionId, String answer) async {
    final response = await _dio.post<Map<String, dynamic>>(
      QuizUrls.submitQuestion(questionId),
      data: <String, dynamic>{"answer": answer},
    );
    return QuestionCheckResultModel.fromJson(
      response.data!["result"] as Map<String, dynamic>,
    );
  }

  /// Submits manually-typed answers keyed by question ID (not question
  /// NUMBER, which is not unique within a quiz when it has both an MCQ and
  /// an SAQ section that each number their questions 1..N).
  Future<QuizDetailModel> submitAnswerKeyManual(
    int quizId,
    List<MapEntry<int, String>> answers,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      QuizUrls.answerKeyManual(quizId),
      data: <String, dynamic>{
        "answers": answers
            .map((entry) => {"question_id": entry.key, "answer": entry.value})
            .toList(),
      },
    );
    return QuizDetailModel.fromJson(response.data!["quiz"] as Map<String, dynamic>);
  }

  Future<QuizDetailModel> uploadAnswerKeyDocument(
    int quizId,
    String filename,
    List<int> bytes,
  ) async {
    final formData = FormData.fromMap(<String, dynamic>{
      "file": MultipartFile.fromBytes(bytes, filename: filename),
    });
    final response = await _dio.post<Map<String, dynamic>>(
      QuizUrls.answerKeyUpload(quizId),
      data: formData,
    );
    return QuizDetailModel.fromJson(response.data!["quiz"] as Map<String, dynamic>);
  }

  Future<CorrectedAnswerModel> correctQuestionAnswer(int questionId, String answer) async {
    final response = await _dio.post<Map<String, dynamic>>(
      QuizUrls.correctQuestion(questionId),
      data: <String, dynamic>{"answer": answer},
    );
    return CorrectedAnswerModel.fromJson(response.data!);
  }
}
