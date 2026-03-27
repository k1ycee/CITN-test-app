import "dart:convert";

import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:http/http.dart" as http;

const String defaultApiBaseUrl = "http://127.0.0.1:5000/api";

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

  List<QuizSummary> _quizzes = const <QuizSummary>[];
  QuizDetail? _selectedQuiz;
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

  Future<void> _refresh({int? focusQuizId}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final quizzes = await _api.fetchQuizzes();
      QuizDetail? detail;
      if (quizzes.isNotEmpty) {
        final quizId = focusQuizId ?? _selectedQuiz?.id ?? quizzes.first.id;
        detail = await _api.fetchQuiz(quizId);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _quizzes = quizzes;
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

  void _syncAnswers({required bool clearExisting}) {
    if (clearExisting) {
      _answers.clear();
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
      final quiz = await _api.uploadPdf(file.name, bytes);
      if (!mounted) {
        return;
      }
      await _refresh(focusQuizId: quiz.id);
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

  @override
  Widget build(BuildContext context) {
    final quiz = _selectedQuiz;
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
                    quizzes: _quizzes,
                    selectedQuizId: quiz?.id,
                    onSelect: _selectQuiz,
                  );
                  final workspace = _QuizWorkspace(
                    quiz: quiz,
                    answers: _answers,
                    submission: _submission,
                    submitting: _submitting,
                    onChange: (id, value) {
                      setState(() {
                        _answers[id] = value;
                      });
                    },
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
    required this.quizzes,
    required this.selectedQuizId,
    required this.onSelect,
  });

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
            if (quizzes.isEmpty)
              const Text("No quizzes yet. Upload a PDF to start."),
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
    required this.submitting,
    required this.onChange,
    required this.onSubmit,
  });

  final QuizDetail? quiz;
  final Map<int, String> answers;
  final SubmissionSummary? submission;
  final bool submitting;
  final void Function(int id, String value) onChange;
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
                  onChanged: (value) => onChange(question.id, value),
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
    required this.onChanged,
  });

  final QuestionItem question;
  final String currentAnswer;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD7DED3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Q${question.questionNumber} [${question.questionType}]",
            style: const TextStyle(fontWeight: FontWeight.w700),
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
        ],
      ),
    );
  }
}

class QuizApi {
  QuizApi({String? baseUrl}) : baseUrl = baseUrl ?? defaultApiBaseUrl;

  final String baseUrl;

  Uri _uri(String path) => Uri.parse("$baseUrl$path");

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

  Future<QuizDetail> uploadPdf(String filename, List<int> bytes) async {
    final request = http.MultipartRequest("POST", _uri("/upload"))
      ..files.add(http.MultipartFile.fromBytes("file", bytes, filename: filename));
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    _throwIfFailed(response);
    return QuizDetail.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
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
  final List<SubmissionResult> results;

  factory SubmissionSummary.fromJson(Map<String, dynamic> json) {
    final summary = json["summary"] as Map<String, dynamic>;
    final resultsJson = json["results"] as List<dynamic>? ?? <dynamic>[];
    return SubmissionSummary(
      score: summary["score"] as int? ?? 0,
      totalQuestions: summary["total_questions"] as int? ?? 0,
      percentage: (summary["percentage"] as num?)?.toDouble() ?? 0,
      results: resultsJson
          .map((item) => SubmissionResult.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

class SubmissionResult {
  SubmissionResult({
    required this.questionNumber,
    required this.questionType,
    required this.status,
    required this.explanation,
  });

  final int questionNumber;
  final String questionType;
  final String status;
  final String explanation;

  factory SubmissionResult.fromJson(Map<String, dynamic> json) {
    return SubmissionResult(
      questionNumber: json["question_number"] as int? ?? 0,
      questionType: json["question_type"] as String? ?? "SAQ",
      status: json["status"] as String? ?? "incorrect",
      explanation: json["explanation"] as String? ?? "",
    );
  }
}
