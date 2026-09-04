import "package:dio/dio.dart";
import "package:hooks_riverpod/hooks_riverpod.dart";
import "package:hooks_riverpod/legacy.dart";

import "api/clients/quiz_client/quiz_client.dart";
import "constants/app_constants.dart";
import "repositories/quiz/quiz_repo.dart";
import "view_models/quiz_vm.dart";

final dioProvider = Provider<Dio>((ref) {
  return Dio(BaseOptions(baseUrl: defaultApiBaseUrl));
});

final quizClientProvider = Provider<QuizClient>((ref) {
  return QuizClient(ref.watch(dioProvider));
});

final quizRepositoryProvider = Provider<QuizRepository>((ref) {
  return QuizRepository(ref.watch(quizClientProvider));
});

final quizViewModelProvider = ChangeNotifierProvider<QuizViewModel>((ref) {
  final vm = QuizViewModel(ref.watch(quizRepositoryProvider));
  vm.init();
  return vm;
});
