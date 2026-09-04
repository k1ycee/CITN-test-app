class CourseSummaryModel {
  CourseSummaryModel({
    required this.id,
    required this.name,
    required this.quizCount,
  });

  final int id;
  final String name;
  final int quizCount;

  factory CourseSummaryModel.fromJson(Map<String, dynamic> json) {
    return CourseSummaryModel(
      id: json["id"] as int,
      name: json["name"] as String? ?? "Unknown Course",
      quizCount: json["quiz_count"] as int? ?? 0,
    );
  }
}
