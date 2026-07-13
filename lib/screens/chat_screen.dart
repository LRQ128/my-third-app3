import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:mime/mime.dart';
import '../models/chat_message.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();
  File? _pendingImage;
  bool _isProcessing = false;

  // Backend URL - configurable
  String get _backendUrl => "http://10.0.2.2:5078"; // Android emulator -> host

  @override
  void initState() {
    super.initState();
    _addWelcomeMessage();
  }

  void _addWelcomeMessage() {
    setState(() {
      _messages.add(ChatMessage(
        text: "👋 你好！发一张图片和你的修图需求给我，我来帮你处理！\n\n"
            "例如：\n"
            "• 「把背景换成海边」\n"
            "• 「帮我去掉水印」\n"
            "• 「把文字'你好'改成'再见'」\n"
            "• 「给我加个复古滤镜」\n"
            "• 「把这张图抠出来」",
        isUser: false,
        time: DateTime.now(),
      ));
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _pickImage() async {
    if (_isProcessing) return;

    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 90,
      );
      if (image != null) {
        setState(() {
          _pendingImage = File(image.path);
        });
        
        // Add message showing selected image
        setState(() {
          _messages.add(ChatMessage(
            text: "已选择图片，请输入修图需求",
            isUser: false,
            time: DateTime.now(),
            imagePath: image.path,
          ));
        });
        _scrollToBottom();
      }
    } catch (e) {
      _showError("选择图片失败");
    }
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty && _pendingImage == null) return;

    setState(() {
      _isProcessing = true;
      // Add user message
      _messages.add(ChatMessage(
        text: text,
        isUser: true,
        time: DateTime.now(),
        imagePath: _pendingImage?.path,
      ));
    });
    _textController.clear();
    _scrollToBottom();

    // Process
    await _processImage(text);

    setState(() {
      _pendingImage = null;
      _isProcessing = false;
    });
  }

  Future<void> _processImage(String userText) async {
    try {
      // Add processing status
      setState(() {
        _messages.add(ChatMessage(
          text: "⏳ 正在调用美图API处理，请稍候...",
          isUser: false,
          time: DateTime.now(),
          isLoading: true,
        ));
      });
      _scrollToBottom();

      // Prepare multipart request
      final uri = Uri.parse("$_backendUrl/api/edit");
      final request = http.MultipartRequest("POST", uri);

      // Add image if available
      if (_pendingImage != null && _pendingImage!.existsSync()) {
        request.files.add(await http.MultipartFile.fromPath(
          "image",
          _pendingImage!.path,
        ));
      }

      // Add text instruction
      request.fields["text"] = userText;

      // Send request
      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 120),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200) {
        final errorData = jsonDecode(response.body);
        _replaceLastAssistantMessage(ChatMessage(
          text: "❌ 处理失败：${errorData['error'] ?? '未知错误'}",
          isUser: false,
          time: DateTime.now(),
        ));
        return;
      }

      final data = jsonDecode(response.body);
      final explanation = data['explanation'] ?? '处理完成';
      final resultUrl = data['result_image_url'];
      final toolUsed = data['tool_used'];
      final creditConsumed = data['credit_consumed'];
      final creditRemaining = data['credit_remaining'];

      // Build response
      String responseText = "✅ $explanation\n\n";
      responseText += "🔧 使用工具：$toolUsed\n";

      if (creditConsumed != null) {
        responseText += "💳 消耗积分：$creditConsumed\n";
      }
      if (creditRemaining != null) {
        responseText += "📊 剩余积分：$creditRemaining";
      }

      if (resultUrl != null) {
        final fullUrl = "$_backendUrl$resultUrl";
        _replaceLastAssistantMessage(ChatMessage(
          text: responseText,
          isUser: false,
          time: DateTime.now(),
          resultImageUrl: fullUrl,
        ));
      } else {
        _replaceLastAssistantMessage(ChatMessage(
          text: responseText + "\n\n⚠️ 未返回处理结果图片",
          isUser: false,
          time: DateTime.now(),
        ));
      }

    } catch (e) {
      _replaceLastAssistantMessage(ChatMessage(
        text: "❌ 网络错误：${e.toString()}",
        isUser: false,
        time: DateTime.now(),
      ));
    }
    _scrollToBottom();
  }

  void _replaceLastAssistantMessage(ChatMessage newMessage) {
    setState(() {
      // Remove the loading message
      if (_messages.isNotEmpty && _messages.last.isLoading) {
        _messages.removeLast();
      }
      _messages.add(newMessage);
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI修图'),
        centerTitle: true,
        actions: [
          if (_pendingImage != null)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消选择图片',
              onPressed: () => setState(() => _pendingImage = null),
            ),
        ],
      ),
      body: Column(
        children: [
          // Chat messages
          Expanded(
            child: _messages.isEmpty
                ? const Center(child: Text('来开始修图吧！'))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      return _buildMessageBubble(_messages[index], theme);
                    },
                  ),
          ),
          // Pending image preview
          if (_pendingImage != null)
            _buildPendingImagePreview(),
          // Input bar
          _buildInputBar(theme),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, ThemeData theme) {
    final alignment = msg.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bgColor = msg.isUser
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceVariant;
    final textColor = msg.isUser
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          // Attached image (user)
          if (msg.isUser && msg.imagePath != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(msg.imagePath!),
                  width: 200,
                  height: 200,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          // Result image (bot)
          if (!msg.isUser && msg.resultImageUrl != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InkWell(
                onTap: () => _showFullImage(msg.resultImageUrl!),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    msg.resultImageUrl!,
                    width: 250,
                    height: 250,
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Container(
                        width: 250,
                        height: 250,
                        color: Colors.grey[200],
                        child: Center(
                          child: CircularProgressIndicator(
                            value: loadingProgress.expectedTotalBytes != null
                                ? loadingProgress.cumulativeBytesLoaded /
                                    loadingProgress.expectedTotalBytes!
                                : null,
                          ),
                        ),
                      );
                    },
                    errorBuilder: (_, __, ___) => Container(
                      width: 250,
                      height: 200,
                      color: Colors.grey[200],
                      child: const Center(child: Text('图片加载失败')),
                    ),
                  ),
                ),
              ),
            ),
          // Loading indicator
          if (msg.isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          // Text
          if (msg.text.isNotEmpty)
            Container(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(18).copyWith(
                  bottomLeft: msg.isUser ? const Radius.circular(18) : const Radius.circular(4),
                  bottomRight: msg.isUser ? const Radius.circular(4) : const Radius.circular(18),
                ),
              ),
              child: Text(
                msg.text,
                style: TextStyle(color: textColor, fontSize: 15),
              ),
            ),
          // Time
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 8, right: 8),
            child: Text(
              "${msg.time.hour.toString().padLeft(2, '0')}:${msg.time.minute.toString().padLeft(2, '0')}",
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingImagePreview() {
    return Container(
      height: 80,
      color: Colors.grey[100],
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              _pendingImage!,
              width: 60,
              height: 60,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "已选择图片，输入修图需求后发送",
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(ThemeData theme) {
    return Container(
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 4,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: Row(
        children: [
          // Image picker button
          IconButton(
            icon: const Icon(Icons.image_outlined),
            color: theme.colorScheme.primary,
            onPressed: _isProcessing ? null : _pickImage,
          ),
          // Text input
          Expanded(
            child: TextField(
              controller: _textController,
              enabled: !_isProcessing,
              decoration: InputDecoration(
                hintText: _pendingImage != null ? '输入修图需求...' : '先选图片，再输入需求...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceVariant,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
              maxLines: 3,
              minLines: 1,
            ),
          ),
          const SizedBox(width: 4),
          // Send button
          IconButton.filled(
            icon: const Icon(Icons.send_rounded),
            color: theme.colorScheme.onPrimary,
            onPressed: _isProcessing ? null : _sendMessage,
          ),
        ],
      ),
    );
  }

  void _showFullImage(String url) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: const Text('修图结果'),
          ),
          body: Center(
            child: InteractiveViewer(
              child: Image.network(url, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }
}
