class QuestionItemModel {
  QuestionItemModel({
    required this.id,
    required this.questionType,
    required this.questionNumber,
    required this.questionText,
    required this.options,
    required this.answerSource,
    required this.confidence,
  });

  final int id;
  final String questionType;
  final int questionNumber;
  final String questionText;
  final Map<String, String?>? options;
  final String answerSource;
  final int? confidence;

  factory QuestionItemModel.fromJson(Map<String, dynamic> json) {
    final rawOptions = json["options"] as Map<String, dynamic>?;
    return QuestionItemModel(
      id: json["id"] as int,
      questionType: json["question_type"] as String? ?? "SAQ",
      questionNumber: json["question_number"] as int? ?? 0,
      questionText: json["question_text"] as String? ?? "",
      options: rawOptions?.map((key, value) => MapEntry(key, value as String?)),
      answerSource: json["answer_source"] as String? ?? "unknown",
      confidence: json["confidence"] as int?,
    );
  }
}
