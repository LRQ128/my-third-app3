class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime time;
  final String? imagePath;      // User's selected image
  final String? resultImageUrl; // Bot's processed result
  final bool isLoading;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.time,
    this.imagePath,
    this.resultImageUrl,
    this.isLoading = false,
  });
}
