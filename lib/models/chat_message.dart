class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime time;
  final String? imagePath;        // User's selected image
  final String? resultImageUrl;   // Bot's processed result (API URL)
  final String? resultImagePath;  // Local file path of saved result image
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
