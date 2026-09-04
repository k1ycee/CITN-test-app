class SubmittedAnswerModel {
  SubmittedAnswerModel({required this.questionId, required this.answer});

  final int questionId;
  final String answer;

  Map<String, dynamic> toJson() => <String, dynamic>{
        "question_id": questionId,
        "answer": answer,
      };
}
