import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:hooks_riverpod/hooks_riverpod.dart";

import "../../core/api/models/quiz_detail_model.dart";
import "../../core/providers.dart";

class AnswerKeyPage extends ConsumerStatefulWidget {
  const AnswerKeyPage({super.key, required this.quiz});

  final QuizDetailModel quiz;

  @override
  ConsumerState<AnswerKeyPage> createState() => _AnswerKeyPageState();
}

class _AnswerKeyPageState extends ConsumerState<AnswerKeyPage> {
  final Map<int, TextEditingController> _controllers = <int, TextEditingController>{};
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    for (final question in widget.quiz.questions) {
      _controllers[question.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _saveTypedAnswers() async {
    final answers = <MapEntry<int, String>>[];
    for (final question in widget.quiz.questions) {
      final text = _controllers[question.id]?.text.trim() ?? "";
      if (text.isNotEmpty) {
        answers.add(MapEntry(question.questionNumber, text));
      }
    }
    if (answers.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _submitting = true);
    await ref.read(quizViewModelProvider).submitAnswerKeyManual(widget.quiz.id, answers);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _uploadDocument() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: "PDF", extensions: <String>["pdf"]),
      ],
    );
    if (file == null) {
      return;
    }
    setState(() => _submitting = true);
    final bytes = await file.readAsBytes();
    await ref.read(quizViewModelProvider).uploadAnswerKeyDocument(widget.quiz.id, file.name, bytes);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Add answer key: ${widget.quiz.title}")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            "This document didn't include answers for these questions. Provide them below, "
            "upload a separate answer key, or skip to use the AI's best guesses.",
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _submitting ? null : _uploadDocument,
                icon: const Icon(Icons.upload_file),
                label: const Text("Upload answer key document"),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                child: const Text("Skip"),
              ),
            ],
          ),
          const Divider(height: 32),
          for (final question in widget.quiz.questions)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Q${question.questionNumber}: ${question.questionText}"),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _controllers[question.id],
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: "Correct answer",
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting ? null : _saveTypedAnswers,
            child: Text(_submitting ? "Saving..." : "Save answers"),
          ),
        ],
      ),
    );
  }
}
