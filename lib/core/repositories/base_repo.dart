import "package:dio/dio.dart";
import "package:fpdart/fpdart.dart";

class RequestFailure {
  const RequestFailure(this.message);

  final String message;
}

/// Wraps a client call, turning thrown errors into a [RequestFailure]
/// instead of letting them escape into the view model.
abstract class BaseRepository {
  Future<Either<RequestFailure, T>> handleRequestFailure<T>(
    Future<T> Function() action,
  ) async {
    try {
      return Right(await action());
    } on DioException catch (error) {
      return Left(RequestFailure(_messageFromDioError(error)));
    } catch (error) {
      return Left(RequestFailure(error.toString()));
    }
  }

  String _messageFromDioError(DioException error) {
    final data = error.response?.data;
    if (data is Map<String, dynamic> && data["error"] != null) {
      return data["error"].toString();
    }
    return error.message ?? "Request failed with status ${error.response?.statusCode}";
  }
}
