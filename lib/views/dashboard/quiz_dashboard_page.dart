import "package:flutter/material.dart";
import "package:hooks_riverpod/hooks_riverpod.dart";

import "../../core/providers.dart";
import "../answer_key/answer_key_page.dart";
import "widget/quiz_list.dart";
import "widget/quiz_workspace.dart";

bool shouldShowAnswerKeyPrompt(int? previousPendingId, int? nextPendingId) {
  return nextPendingId != null && previousPendingId != nextPendingId;
}

class QuizDashboardPage extends ConsumerWidget {
  const QuizDashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(quizViewModelProvider);
    final quiz = vm.selectedQuiz;
    final filteredQuizzes = vm.filteredQuizzes;

    ref.listen(quizViewModelProvider, (previous, next) {
      final pendingId = next.pendingAnswerKeyQuizId;
      if (shouldShowAnswerKeyPrompt(previous?.pendingAnswerKeyQuizId, pendingId)) {
        next.dismissPendingAnswerKey();
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FutureBuilder(
              future: next.fetchQuizDetail(pendingId!),
              builder: (context, snapshot) {
                final quiz = snapshot.data;
                if (quiz == null) {
                  return const Scaffold(body: Center(child: CircularProgressIndicator()));
                }
                return AnswerKeyPage(quiz: quiz);
              },
            ),
          ),
        );
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text("PDF Quiz System"),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              onPressed: vm.uploading ? null : vm.upload,
              icon: vm.uploading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file),
              label: Text(vm.uploading ? "Parsing..." : "Upload PDF"),
            ),
          ),
        ],
      ),
      body: vm.loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: vm.refresh,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth > 1000;
                  final list = QuizList(
                    courses: vm.courses,
                    selectedCourseName: vm.selectedCourseName,
                    onCourseChanged: vm.selectCourse,
                    quizzes: filteredQuizzes,
                    selectedQuizId: quiz?.id,
                    onSelect: vm.selectQuiz,
                  );
                  final workspace = QuizWorkspace(
                    quiz: quiz,
                    answers: vm.answers,
                    submission: vm.submission,
                    questionResults: vm.questionResults,
                    checkingQuestionIds: vm.checkingQuestionIds,
                    submitting: vm.submitting,
                    onChange: vm.handleAnswerChange,
                    onCheckQuestion: vm.checkQuestion,
                    onSubmit: vm.submit,
                  );

                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (vm.error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Material(
                            color: const Color(0xFFFFE5E5),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(vm.error!),
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
