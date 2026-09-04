class QuizUrls {
  const QuizUrls._();

  static const String courses = "/courses";
  static const String quizzes = "/quizzes";
  static const String upload = "/upload";

  static String quiz(int id) => "/quizzes/$id";
  static String uploadJob(String jobId) => "/uploads/$jobId";
  static String submitQuiz(int quizId) => "/quizzes/$quizId/submit";
  static String submitQuestion(int questionId) => "/questions/$questionId/submit";
}
