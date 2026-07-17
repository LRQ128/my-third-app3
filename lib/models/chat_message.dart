class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime time;
  final String? imagePath;        // User's selected image
  final String? resultImageUrl;   // Remote result URL (from API)
  String? resultImagePath;        // Local file path of saved result image
  final bool isLoading;
  final String? beforeImagePath;  // Original image for history comparison

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.time,
    this.imagePath,
    this.resultImageUrl,
    this.resultImagePath,
    this.isLoading = false,
    this.beforeImagePath,
  });
}
