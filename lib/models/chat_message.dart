class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime time;
  final String? imagePath;
  final String? resultImageUrl;
  final String? resultImagePath;
  final bool isLoading;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.time,
    this.imagePath,
    this.resultImageUrl,
    this.resultImagePath,
    this.isLoading = false,
  });
}
