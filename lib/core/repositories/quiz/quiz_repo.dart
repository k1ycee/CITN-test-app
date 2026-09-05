import "package:fpdart/fpdart.dart";

import "../../api/clients/quiz_client/quiz_client.dart";
import "../../api/models/corrected_answer_model.dart";
import "../../api/models/course_summary_model.dart";
import "../../api/models/question_check_result_model.dart";
import "../../api/models/quiz_detail_model.dart";
import "../../api/models/quiz_summary_model.dart";
import "../../api/models/submission_summary_model.dart";
import "../../api/models/submitted_answer_model.dart";
import "../../api/models/upload_result_model.dart";
import "../../constants/app_constants.dart";
import "../base_repo.dart";

class QuizRepository extends BaseRepository {
  QuizRepository(this._client);

  final QuizClient _client;

  Future<Either<RequestFailure, List<CourseSummaryModel>>> fetchCourses() =>
      handleRequestFailure(_client.fetchCourses);

  Future<Either<RequestFailure, List<QuizSummaryModel>>> fetchQuizzes() =>
      handleRequestFailure(_client.fetchQuizzes);

  Future<Either<RequestFailure, QuizDetailModel>> fetchQuiz(int quizId) =>
      handleRequestFailure(() => _client.fetchQuiz(quizId));

  /// Uploads the PDF, then polls the resulting job (if async) until it
  /// completes, fails, or times out.
  Future<Either<RequestFailure, UploadResultModel>> uploadPdf(
    String filename,
    List<int> bytes,
  ) {
    return handleRequestFailure(() async {
      final initial = await _client.uploadPdf(filename, bytes);
      if (initial.jobId == null) {
        return initial;
      }
      return _waitForUploadJob(initial.jobId!);
    });
  }

  Future<UploadResultModel> _waitForUploadJob(String jobId) async {
    final deadline = DateTime.now().add(uploadJobTimeout);

    while (DateTime.now().isBefore(deadline)) {
      final job = await _client.fetchUploadJob(jobId);

      if (job.status == "completed") {
        if (job.quizzes.isEmpty) {
          throw Exception("Upload finished, but no quizzes were created.");
        }
        return UploadResultModel(primaryQuizId: job.quizzes.first.id, jobId: job.jobId);
      }

      if (job.status == "failed") {
        final errorMessage = job.errors.isNotEmpty
            ? job.errors.map((error) => error.message).join("; ")
            : "Upload job failed.";
        throw Exception(errorMessage);
      }

      await Future<void>.delayed(uploadJobPollInterval);
    }

    throw Exception("Upload is still processing. Try again in a moment.");
  }

  Future<Either<RequestFailure, SubmissionSummaryModel>> submitQuiz(
    int quizId,
    List<SubmittedAnswerModel> answers,
  ) => handleRequestFailure(() => _client.submitQuiz(quizId, answers));

  Future<Either<RequestFailure, QuestionCheckResultModel>> submitQuestion(
    int questionId,
    String answer,
  ) => handleRequestFailure(() => _client.submitQuestion(questionId, answer));

  Future<Either<RequestFailure, QuizDetailModel>> submitAnswerKeyManual(
    int quizId,
    List<MapEntry<int, String>> answers,
  ) => handleRequestFailure(() => _client.submitAnswerKeyManual(quizId, answers));

  Future<Either<RequestFailure, QuizDetailModel>> uploadAnswerKeyDocument(
    int quizId,
    String filename,
    List<int> bytes,
  ) => handleRequestFailure(() => _client.uploadAnswerKeyDocument(quizId, filename, bytes));

  Future<Either<RequestFailure, CorrectedAnswerModel>> correctQuestionAnswer(
    int questionId,
    String answer,
  ) => handleRequestFailure(() => _client.correctQuestionAnswer(questionId, answer));
}
