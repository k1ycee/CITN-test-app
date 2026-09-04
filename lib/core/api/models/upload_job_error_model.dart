class UploadJobErrorModel {
  UploadJobErrorModel({required this.topic, required this.message});

  final String topic;
  final String message;

  factory UploadJobErrorModel.fromJson(Map<String, dynamic> json) {
    return UploadJobErrorModel(
      topic: json["topic"] as String? ?? "unknown",
      message: json["error"] as String? ?? "Unknown upload error",
    );
  }
}
