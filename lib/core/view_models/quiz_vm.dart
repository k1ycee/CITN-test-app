import "dart:async";

import "package:file_selector/file_selector.dart";
import "package:fpdart/fpdart.dart";

import "../api/models/course_summary_model.dart";
import "../api/models/question_check_result_model.dart";
import "../api/models/question_item_model.dart";
import "../api/models/quiz_detail_model.dart";
import "../api/models/quiz_summary_model.dart";
import "../api/models/submission_summary_model.dart";
import "../api/models/submitted_answer_model.dart";
import "../constants/app_constants.dart";
import "../repositories/base_repo.dart";
import "../repositories/quiz/quiz_repo.dart";
import "base/disposable_view_model.dart";

class QuizViewModel extends DisposableViewModel {
  QuizViewModel(this._repo);

  final QuizRepository _repo;

  final Map<int, String> _answers = <int, String>{};
  final Map<int, QuestionCheckResultModel> _questionResults =
      <int, QuestionCheckResultModel>{};
  final Map<int, Timer> _answerDebouncers = <int, Timer>{};
  final Set<int> _checkingQuestionIds = <int>{};

  List<CourseSummaryModel> _courses = const <CourseSummaryModel>[];
  List<QuizSummaryModel> _quizzes = const <QuizSummaryModel>[];
  QuizDetailModel? _selectedQuiz;
  String? _selectedCourseName;
  SubmissionSummaryModel? _submission;
  bool _loading = true;
  bool _uploading = false;
  bool _submitting = false;
  String? _error;

  List<CourseSummaryModel> get courses => _courses;
  List<QuizSummaryModel> get filteredQuizzes =>
      _filterQuizzesByCourse(_quizzes, _selectedCourseName);
  QuizDetailModel? get selectedQuiz => _selectedQuiz;
  String? get selectedCourseName => _selectedCourseName;
  SubmissionSummaryModel? get submission => _submission;
  Map<int, String> get answers => _answers;
  Map<int, QuestionCheckResultModel> get questionResults => _questionResults;
  Set<int> get checkingQuestionIds => _checkingQuestionIds;
  bool get loading => _loading;
  bool get uploading => _uploading;
  bool get submitting => _submitting;
  String? get error => _error;

  Future<void> init() => refresh();

  @override
  void dispose() {
    for (final timer in _answerDebouncers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  /// Unwraps an [Either], recording the failure message on the left branch.
  T? _unwrap<T>(Either<RequestFailure, T> either) {
    return either.fold((failure) {
      _error = failure.message;
      return null;
    }, (value) => value);
  }

  Future<void> refresh({int? focusQuizId}) async {
    _loading = true;
    _error = null;
    notify();

    final coursesFuture = _repo.fetchCourses();
    final quizzesFuture = _repo.fetchQuizzes();
    final courses = _unwrap(await coursesFuture);
    final quizzes = _unwrap(await quizzesFuture);

    if (courses == null || quizzes == null) {
      _loading = false;
      notify();
      return;
    }

    final nextCourseName = _resolveSelectedCourseName(
      courses: courses,
      quizzes: quizzes,
      focusedQuizId: focusQuizId,
    );
    final filtered = _filterQuizzesByCourse(quizzes, nextCourseName);

    QuizDetailModel? detail;
    if (filtered.isNotEmpty) {
      final quizId = _resolveSelectedQuizId(
        quizzes: filtered,
        focusedQuizId: focusQuizId,
      );
      detail = _unwrap(await _repo.fetchQuiz(quizId));
      if (detail == null) {
        _loading = false;
        notify();
        return;
      }
    }

    _courses = courses;
    _quizzes = quizzes;
    _selectedCourseName = nextCourseName;
    _selectedQuiz = detail;
    _submission = null;
    _loading = false;
    _syncAnswers(clearExisting: false);
    notify();
  }

  List<QuizSummaryModel> _filterQuizzesByCourse(
    List<QuizSummaryModel> quizzes,
    String? courseName,
  ) {
    if (courseName == null || courseName.isEmpty) {
      return quizzes;
    }
    return quizzes.where((quiz) => quiz.courseName == courseName).toList();
  }

  String? _resolveSelectedCourseName({
    required List<CourseSummaryModel> courses,
    required List<QuizSummaryModel> quizzes,
    int? focusedQuizId,
  }) {
    if (courses.isEmpty) {
      return null;
    }

    if (focusedQuizId != null) {
      QuizSummaryModel? focusedQuiz;
      for (final quiz in quizzes) {
        if (quiz.id == focusedQuizId) {
          focusedQuiz = quiz;
          break;
        }
      }
      if (focusedQuiz != null) {
        return focusedQuiz.courseName;
      }
    }

    final currentCourse = _selectedCourseName;
    if (currentCourse != null &&
        courses.any((course) => course.name == currentCourse)) {
      return currentCourse;
    }

    final selectedQuiz = _selectedQuiz;
    if (selectedQuiz != null &&
        courses.any((course) => course.name == selectedQuiz.courseName)) {
      return selectedQuiz.courseName;
    }

    return courses.first.name;
  }

  int _resolveSelectedQuizId({
    required List<QuizSummaryModel> quizzes,
    int? focusedQuizId,
  }) {
    if (focusedQuizId != null &&
        quizzes.any((quiz) => quiz.id == focusedQuizId)) {
      return focusedQuizId;
    }

    final selectedQuizId = _selectedQuiz?.id;
    if (selectedQuizId != null &&
        quizzes.any((quiz) => quiz.id == selectedQuizId)) {
      return selectedQuizId;
    }

    return quizzes.first.id;
  }

  void _syncAnswers({required bool clearExisting}) {
    if (clearExisting) {
      _answers.clear();
      _questionResults.clear();
      _checkingQuestionIds.clear();
      for (final timer in _answerDebouncers.values) {
        timer.cancel();
      }
      _answerDebouncers.clear();
    }
    final quiz = _selectedQuiz;
    if (quiz == null) {
      return;
    }
    for (final question in quiz.questions) {
      _answers.putIfAbsent(question.id, () => "");
    }
  }

  Future<void> selectQuiz(int id) async {
    _error = null;
    _submission = null;
    notify();

    final detail = _unwrap(await _repo.fetchQuiz(id));
    if (detail == null) {
      notify();
      return;
    }

    _selectedQuiz = detail;
    _syncAnswers(clearExisting: true);
    notify();
  }

  Future<void> selectCourse(String? courseName) async {
    if (courseName == null || courseName == _selectedCourseName) {
      return;
    }

    final quizzesForCourse = _filterQuizzesByCourse(_quizzes, courseName);

    _selectedCourseName = courseName;
    _selectedQuiz = null;
    _submission = null;
    _error = null;
    _syncAnswers(clearExisting: true);
    notify();

    if (quizzesForCourse.isEmpty) {
      return;
    }

    await selectQuiz(quizzesForCourse.first.id);
  }

  Future<void> upload() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: "PDF", extensions: <String>["pdf"]),
      ],
    );
    if (file == null) {
      return;
    }

    _uploading = true;
    _error = null;
    notify();

    final bytes = await file.readAsBytes();
    final uploadResult = _unwrap(await _repo.uploadPdf(file.name, bytes));

    if (uploadResult != null) {
      if (uploadResult.primaryQuizId == null) {
        _error = "Upload completed but no quiz was returned.";
      } else {
        await refresh(focusQuizId: uploadResult.primaryQuizId);
      }
    }

    _uploading = false;
    notify();
  }

  Future<void> submit() async {
    final quiz = _selectedQuiz;
    if (quiz == null) {
      return;
    }

    _submitting = true;
    _error = null;
    notify();

    final payload = quiz.questions
        .map(
          (question) => SubmittedAnswerModel(
            questionId: question.id,
            answer: _answers[question.id] ?? "",
          ),
        )
        .toList();
    final result = _unwrap(await _repo.submitQuiz(quiz.id, payload));

    if (result != null) {
      _submission = result;
      for (final questionResult in result.results) {
        _questionResults[questionResult.questionId] = questionResult;
      }
    }

    _submitting = false;
    notify();
  }

  void handleAnswerChange(QuestionItemModel question, String value) {
    _answers[question.id] = value;
    _questionResults.remove(question.id);
    notify();

    _answerDebouncers[question.id]?.cancel();

    if (value.trim().isEmpty) {
      _checkingQuestionIds.remove(question.id);
      notify();
      return;
    }

    if (question.questionType == "MCQ") {
      unawaited(_checkSingleQuestion(question.id, value));
      return;
    }

    if (question.questionType == "SAQ") {
      _checkingQuestionIds.remove(question.id);
      return;
    }

    _answerDebouncers[question.id] = Timer(textAnswerDebounce, () {
      unawaited(_checkSingleQuestion(question.id, value));
    });
  }

  Future<void> checkQuestion(QuestionItemModel question) async {
    final answer = (_answers[question.id] ?? "").trim();
    if (answer.isEmpty) {
      return;
    }
    await _checkSingleQuestion(question.id, answer);
  }

  Future<void> _checkSingleQuestion(int questionId, String answer) async {
    if ((_answers[questionId] ?? "") != answer) {
      return;
    }

    _checkingQuestionIds.add(questionId);
    _error = null;
    notify();

    final result = _unwrap(await _repo.submitQuestion(questionId, answer));
    if ((_answers[questionId] ?? "") != answer) {
      return;
    }

    if (result != null) {
      _questionResults[questionId] = result;
    }
    _checkingQuestionIds.remove(questionId);
    notify();
  }
}
