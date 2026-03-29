import "dart:async";
import "dart:convert";

import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:http/http.dart" as http;

const String defaultApiBaseUrl = "http://192.168.1.52:3000/api";
const Duration textAnswerDebounce = Duration(milliseconds: 700);

void main() {
  runApp(const PdfQuizApp());
}

class PdfQuizApp extends StatelessWidget {
  const PdfQuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0B6E4F),
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: "PDF Quiz System",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF5F1E8),
        useMaterial3: true,
      ),
      home: const QuizDashboardPage(),
    );
  }
}

class QuizDashboardPage extends StatefulWidget {
  const QuizDashboardPage({super.key});

  @override
  State<QuizDashboardPage> createState() => _QuizDashboardPageState();
}

class _QuizDashboardPageState extends State<QuizDashboardPage> {
  final QuizApi _api = QuizApi();
  final Map<int, String> _answers = <int, String>{};
  final Map<int, QuestionCheckResult> _questionResults =
      <int, QuestionCheckResult>{};
  final Map<int, Timer> _answerDebouncers = <int, Timer>{};
  final Set<int> _checkingQuestionIds = <int>{};

  List<CourseSummary> _courses = const <CourseSummary>[];
  List<QuizSummary> _quizzes = const <QuizSummary>[];
  QuizDetail? _selectedQuiz;
  String? _selectedCourseName;
  SubmissionSummary? _submission;
  bool _loading = true;
  bool _uploading = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    for (final timer in _answerDebouncers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  Future<void> _refresh({int? focusQuizId}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        _api.fetchCourses(),
        _api.fetchQuizzes(),
      ]);
      final courses = results[0] as List<CourseSummary>;
      final quizzes = results[1] as List<QuizSummary>;
      final nextCourseName = _resolveSelectedCourseName(
        courses: courses,
        quizzes: quizzes,
        focusedQuizId: focusQuizId,
      );
      final filteredQuizzes = _filterQuizzesByCourse(quizzes, nextCourseName);
      QuizDetail? detail;
      if (filteredQuizzes.isNotEmpty) {
        final quizId = _resolveSelectedQuizId(
          quizzes: filteredQuizzes,
          focusedQuizId: focusQuizId,
        );
        detail = await _api.fetchQuiz(quizId);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _courses = courses;
        _quizzes = quizzes;
        _selectedCourseName = nextCourseName;
        _selectedQuiz = detail;
        _submission = null;
        _loading = false;
        _syncAnswers(clearExisting: false);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  List<QuizSummary> _filterQuizzesByCourse(
    List<QuizSummary> quizzes,
    String? courseName,
  ) {
    if (courseName == null || courseName.isEmpty) {
      return quizzes;
    }
    return quizzes.where((quiz) => quiz.courseName == courseName).toList();
  }

  String? _resolveSelectedCourseName({
    required List<CourseSummary> courses,
    required List<QuizSummary> quizzes,
    int? focusedQuizId,
  }) {
    if (courses.isEmpty) {
      return null;
    }

    if (focusedQuizId != null) {
      QuizSummary? focusedQuiz;
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
    required List<QuizSummary> quizzes,
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

  Future<void> _selectQuiz(int id) async {
    setState(() {
      _error = null;
      _submission = null;
    });
    try {
      final detail = await _api.fetchQuiz(id);
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedQuiz = detail;
        _syncAnswers(clearExisting: true);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
      });
    }
  }

  Future<void> _selectCourse(String? courseName) async {
    if (courseName == null || courseName == _selectedCourseName) {
      return;
    }

    final quizzesForCourse = _filterQuizzesByCourse(_quizzes, courseName);

    setState(() {
      _selectedCourseName = courseName;
      _selectedQuiz = null;
      _submission = null;
      _error = null;
      _syncAnswers(clearExisting: true);
    });

    if (quizzesForCourse.isEmpty) {
      return;
    }

    await _selectQuiz(quizzesForCourse.first.id);
  }

  Future<void> _upload() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: "PDF", extensions: <String>["pdf"]),
      ],
    );
    if (file == null) {
      return;
    }

    setState(() {
      _uploading = true;
      _error = null;
    });

    try {
      final bytes = await file.readAsBytes();
      final uploadResult = await _api.uploadPdf(file.name, bytes);
      if (!mounted) {
        return;
      }
      await _refresh(focusQuizId: uploadResult.primaryQuizId);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
        });
      }
    }
  }

  Future<void> _submit() async {
    final quiz = _selectedQuiz;
    if (quiz == null) {
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final payload = quiz.questions
          .map(
            (question) => SubmittedAnswer(
              questionId: question.id,
              answer: _answers[question.id] ?? "",
            ),
          )
          .toList();
      final submission = await _api.submitQuiz(quiz.id, payload);
      if (!mounted) {
        return;
      }
      setState(() {
        _submission = submission;
        for (final result in submission.results) {
          _questionResults[result.questionId] = result;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  void _handleAnswerChange(QuestionItem question, String value) {
    setState(() {
      _answers[question.id] = value;
      _questionResults.remove(question.id);
    });

    _answerDebouncers[question.id]?.cancel();

    if (value.trim().isEmpty) {
      setState(() {
        _checkingQuestionIds.remove(question.id);
      });
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

  Future<void> _checkQuestion(QuestionItem question) async {
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

    setState(() {
      _checkingQuestionIds.add(questionId);
      _error = null;
    });

    try {
      final result = await _api.submitQuestion(questionId, answer);
      if (!mounted) {
        return;
      }
      if ((_answers[questionId] ?? "") != answer) {
        return;
      }
      setState(() {
        _questionResults[questionId] = result;
        _checkingQuestionIds.remove(questionId);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _checkingQuestionIds.remove(questionId);
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final quiz = _selectedQuiz;
    final filteredQuizzes = _filterQuizzesByCourse(_quizzes, _selectedCourseName);
    return Scaffold(
      appBar: AppBar(
        title: const Text("PDF Quiz System"),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              onPressed: _uploading ? null : _upload,
              icon: _uploading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file),
              label: Text(_uploading ? "Parsing..." : "Upload PDF"),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth > 1000;
                  final list = _QuizList(
                    courses: _courses,
                    selectedCourseName: _selectedCourseName,
                    onCourseChanged: _selectCourse,
                    quizzes: filteredQuizzes,
                    selectedQuizId: quiz?.id,
                    onSelect: _selectQuiz,
                  );
                  final workspace = _QuizWorkspace(
                    quiz: quiz,
                    answers: _answers,
                    submission: _submission,
                    questionResults: _questionResults,
                    checkingQuestionIds: _checkingQuestionIds,
                    submitting: _submitting,
                    onChange: _handleAnswerChange,
                    onCheckQuestion: _checkQuestion,
                    onSubmit: _submit,
                  );

                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Material(
                            color: const Color(0xFFFFE5E5),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(_error!),
                            ),
                          ),
                        ),
                      if (wide)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 320, child: list),
                            const SizedBox(width: 16),
                            Expanded(child: workspace),
                          ],
                        )
                      else ...[
                        list,
                        const SizedBox(height: 16),
                        workspace,
                      ],
                    ],
                  );
                },
              ),
            ),
    );
  }
}

class _QuizList extends StatelessWidget {
  const _QuizList({
    required this.courses,
    required this.selectedCourseName,
    required this.onCourseChanged,
    required this.quizzes,
    required this.selectedQuizId,
    required this.onSelect,
  });

  final List<CourseSummary> courses;
  final String? selectedCourseName;
  final ValueChanged<String?> onCourseChanged;
  final List<QuizSummary> quizzes;
  final int? selectedQuizId;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Quiz Library",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            if (courses.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                value: selectedCourseName,
                decoration: const InputDecoration(
                  labelText: "Course",
                  border: OutlineInputBorder(),
                ),
                items: courses
                    .map(
                      (course) => DropdownMenuItem<String>(
                        value: course.name,
                        child: Text("${course.name} (${course.quizCount})"),
                      ),
                    )
                    .toList(),
                onChanged: onCourseChanged,
              ),
              const SizedBox(height: 12),
            ],
            if (quizzes.isEmpty)
              Text(
                courses.isEmpty
                    ? "No quizzes yet. Upload a PDF to start."
                    : "No quizzes found for the selected course.",
              ),
            for (final quiz in quizzes)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  tileColor: selectedQuizId == quiz.id
                      ? const Color(0xFF17332C)
                      : const Color(0xFFF0F3EE),
                  textColor: selectedQuizId == quiz.id ? Colors.white : null,
                  iconColor: selectedQuizId == quiz.id ? Colors.white : null,
                  title: Text(quiz.title),
                  subtitle: Text(
                    "${quiz.courseName} | ${quiz.questionCount} questions",
                  ),
                  onTap: () => onSelect(quiz.id),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _QuizWorkspace extends StatelessWidget {
  const _QuizWorkspace({
    required this.quiz,
    required this.answers,
    required this.submission,
    required this.questionResults,
    required this.checkingQuestionIds,
    required this.submitting,
    required this.onChange,
    required this.onCheckQuestion,
    required this.onSubmit,
  });

  final QuizDetail? quiz;
  final Map<int, String> answers;
  final SubmissionSummary? submission;
  final Map<int, QuestionCheckResult> questionResults;
  final Set<int> checkingQuestionIds;
  final bool submitting;
  final void Function(QuestionItem question, String value) onChange;
  final Future<void> Function(QuestionItem question) onCheckQuestion;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    if (quiz == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text("Select a quiz to see questions."),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              quiz!.title,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text("${quiz!.courseName} | ${quiz!.questionCount} questions"),
            if (submission != null) ...[
              const SizedBox(height: 16),
              Material(
                color: const Color(0xFFE0F0E3),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Score: ${submission!.score}/${submission!.totalQuestions} (${submission!.percentage.toStringAsFixed(2)}%)",
                      ),
                      const SizedBox(height: 8),
                      for (final result in submission!.results)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            "Q${result.questionNumber} ${result.questionType}: ${result.status} - ${result.explanation}",
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            for (final question in quiz!.questions)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _QuestionCard(
                  question: question,
                  currentAnswer: answers[question.id] ?? "",
                  result: questionResults[question.id],
                  isChecking: checkingQuestionIds.contains(question.id),
                  onChanged: (value) => onChange(question, value),
                  onCheck: () => onCheckQuestion(question),
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: submitting ? null : onSubmit,
                icon: submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.task_alt),
                label: Text(submitting ? "Submitting..." : "Submit All Answers"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.currentAnswer,
    required this.result,
    required this.isChecking,
    required this.onChanged,
    required this.onCheck,
  });

  final QuestionItem question;
  final String currentAnswer;
  final QuestionCheckResult? result;
  final bool isChecking;
  final ValueChanged<String> onChanged;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final borderColor = result == null
        ? const Color(0xFFD7DED3)
        : result!.isCorrect
            ? const Color(0xFF2E7D32)
            : const Color(0xFFC62828);
    final backgroundColor = result == null
        ? Colors.white
        : result!.isCorrect
            ? const Color(0xFFE7F6E9)
            : const Color(0xFFFDEAEA);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "Q${question.questionNumber} [${question.questionType}]",
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (isChecking)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (result != null)
                Icon(
                  result!.isCorrect ? Icons.check_circle : Icons.cancel,
                  color: result!.isCorrect
                      ? const Color(0xFF2E7D32)
                      : const Color(0xFFC62828),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(question.questionText),
          const SizedBox(height: 12),
          if (question.questionType == "MCQ" && question.options != null)
            ...question.options!.entries
                .where((entry) => (entry.value ?? "").trim().isNotEmpty)
                .map(
                  (entry) => RadioListTile<String>(
                    value: entry.key.toUpperCase(),
                    groupValue: currentAnswer.isEmpty ? null : currentAnswer,
                    contentPadding: EdgeInsets.zero,
                    title: Text("${entry.key.toUpperCase()}. ${entry.value}"),
                    onChanged: (value) => onChanged(value ?? ""),
                  ),
                )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  initialValue: currentAnswer,
                  minLines: question.questionType == "SEQ" ? 4 : 2,
                  maxLines: question.questionType == "SEQ" ? 6 : 3,
                  onChanged: onChanged,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: "Enter your answer",
                  ),
                ),
                if (question.questionType == "SAQ") ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: currentAnswer.trim().isEmpty || isChecking
                          ? null
                          : onCheck,
                      icon: const Icon(Icons.rule),
                      label: const Text("Check"),
                    ),
                  ),
                ],
              ],
            ),
          if (result != null) ...[
            const SizedBox(height: 12),
            Text(
              result!.isCorrect ? "Correct" : "Incorrect",
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: result!.isCorrect
                    ? const Color(0xFF2E7D32)
                    : const Color(0xFFC62828),
              ),
            ),
            if (result!.hasCorrectAnswer) ...[
              const SizedBox(height: 4),
              Text("Correct answer: ${result!.correctAnswer}"),
            ],
            const SizedBox(height: 4),
            Text(result!.explanation),
          ],
        ],
      ),
    );
  }
}

class QuizApi {
  QuizApi({String? baseUrl}) : baseUrl = baseUrl ?? defaultApiBaseUrl;

  final String baseUrl;

  Uri _uri(String path) => Uri.parse("$baseUrl$path");

  Future<List<CourseSummary>> fetchCourses() async {
    final response = await http.get(_uri("/courses"));
    _throwIfFailed(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => CourseSummary.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<QuizSummary>> fetchQuizzes() async {
    final response = await http.get(_uri("/quizzes"));
    _throwIfFailed(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => QuizSummary.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<QuizDetail> fetchQuiz(int quizId) async {
    final response = await http.get(_uri("/quizzes/$quizId"));
    _throwIfFailed(response);
    return QuizDetail.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<UploadResult> uploadPdf(String filename, List<int> bytes) async {
    final request = http.MultipartRequest("POST", _uri("/upload"))
      ..files.add(http.MultipartFile.fromBytes("file", bytes, filename: filename));
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    _throwIfFailed(response);
    return UploadResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<SubmissionSummary> submitQuiz(int quizId, List<SubmittedAnswer> answers) async {
    final response = await http.post(
      _uri("/quizzes/$quizId/submit"),
      headers: const <String, String>{"Content-Type": "application/json"},
      body: jsonEncode(<String, dynamic>{
        "answers": answers.map((answer) => answer.toJson()).toList(),
      }),
    );
    _throwIfFailed(response);
    return SubmissionSummary.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<QuestionCheckResult> submitQuestion(int questionId, String answer) async {
    final response = await http.post(
      _uri("/questions/$questionId/submit"),
      headers: const <String, String>{"Content-Type": "application/json"},
      body: jsonEncode(<String, dynamic>{"answer": answer}),
    );
    _throwIfFailed(response);
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    return QuestionCheckResult.fromJson(payload["result"] as Map<String, dynamic>);
  }

  void _throwIfFailed(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      throw Exception(data["error"] ?? "Request failed with status ${response.statusCode}");
    } catch (_) {
      throw Exception("Request failed with status ${response.statusCode}");
    }
  }
}

class CourseSummary {
  CourseSummary({
    required this.id,
    required this.name,
    required this.quizCount,
  });

  final int id;
  final String name;
  final int quizCount;

  factory CourseSummary.fromJson(Map<String, dynamic> json) {
    return CourseSummary(
      id: json["id"] as int,
      name: json["name"] as String? ?? "Unknown Course",
      quizCount: json["quiz_count"] as int? ?? 0,
    );
  }
}

class QuizSummary {
  QuizSummary({
    required this.id,
    required this.title,
    required this.courseName,
    required this.questionCount,
  });

  final int id;
  final String title;
  final String courseName;
  final int questionCount;

  factory QuizSummary.fromJson(Map<String, dynamic> json) {
    return QuizSummary(
      id: json["id"] as int,
      title: json["title"] as String? ?? "Untitled Quiz",
      courseName: json["course_name"] as String? ?? "Unknown Course",
      questionCount: json["question_count"] as int? ?? 0,
    );
  }
}

class UploadResult {
  UploadResult({required this.primaryQuizId});

  final int primaryQuizId;

  factory UploadResult.fromJson(Map<String, dynamic> json) {
    if (json.containsKey("id")) {
      return UploadResult(primaryQuizId: json["id"] as int);
    }

    final quizzes = json["quizzes"] as List<dynamic>? ?? <dynamic>[];
    if (quizzes.isNotEmpty) {
      final firstQuiz = quizzes.first as Map<String, dynamic>;
      return UploadResult(primaryQuizId: firstQuiz["id"] as int);
    }

    throw Exception("Upload completed but no quiz was returned.");
  }
}

class QuizDetail {
  QuizDetail({
    required this.id,
    required this.title,
    required this.courseName,
    required this.questionCount,
    required this.questions,
  });

  final int id;
  final String title;
  final String courseName;
  final int questionCount;
  final List<QuestionItem> questions;

  factory QuizDetail.fromJson(Map<String, dynamic> json) {
    final questionsJson = json["questions"] as List<dynamic>? ?? <dynamic>[];
    return QuizDetail(
      id: json["id"] as int,
      title: json["title"] as String? ?? "Untitled Quiz",
      courseName: json["course_name"] as String? ?? "Unknown Course",
      questionCount: json["question_count"] as int? ?? 0,
      questions: questionsJson
          .map((item) => QuestionItem.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

class QuestionItem {
  QuestionItem({
    required this.id,
    required this.questionType,
    required this.questionNumber,
    required this.questionText,
    required this.options,
  });

  final int id;
  final String questionType;
  final int questionNumber;
  final String questionText;
  final Map<String, String?>? options;

  factory QuestionItem.fromJson(Map<String, dynamic> json) {
    final rawOptions = json["options"] as Map<String, dynamic>?;
    return QuestionItem(
      id: json["id"] as int,
      questionType: json["question_type"] as String? ?? "SAQ",
      questionNumber: json["question_number"] as int? ?? 0,
      questionText: json["question_text"] as String? ?? "",
      options: rawOptions?.map((key, value) => MapEntry(key, value as String?)),
    );
  }
}

class SubmittedAnswer {
  SubmittedAnswer({required this.questionId, required this.answer});

  final int questionId;
  final String answer;

  Map<String, dynamic> toJson() => <String, dynamic>{
        "question_id": questionId,
        "answer": answer,
      };
}

class SubmissionSummary {
  SubmissionSummary({
    required this.score,
    required this.totalQuestions,
    required this.percentage,
    required this.results,
  });

  final int score;
  final int totalQuestions;
  final double percentage;
  final List<QuestionCheckResult> results;

  factory SubmissionSummary.fromJson(Map<String, dynamic> json) {
    final summary = json["summary"] as Map<String, dynamic>;
    final resultsJson = json["results"] as List<dynamic>? ?? <dynamic>[];
    return SubmissionSummary(
      score: summary["score"] as int? ?? 0,
      totalQuestions: summary["total_questions"] as int? ?? 0,
      percentage: (summary["percentage"] as num?)?.toDouble() ?? 0,
      results: resultsJson
          .map((item) => QuestionCheckResult.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

class QuestionCheckResult {
  QuestionCheckResult({
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

  factory QuestionCheckResult.fromJson(Map<String, dynamic> json) {
    return QuestionCheckResult(
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
