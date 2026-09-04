import "package:flutter/material.dart";

import "../../../core/api/models/course_summary_model.dart";
import "../../../core/api/models/quiz_summary_model.dart";

class QuizList extends StatelessWidget {
  const QuizList({
    super.key,
    required this.courses,
    required this.selectedCourseName,
    required this.onCourseChanged,
    required this.quizzes,
    required this.selectedQuizId,
    required this.onSelect,
  });

  final List<CourseSummaryModel> courses;
  final String? selectedCourseName;
  final ValueChanged<String?> onCourseChanged;
  final List<QuizSummaryModel> quizzes;
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
                initialValue: selectedCourseName,
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
