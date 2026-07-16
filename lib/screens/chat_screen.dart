import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import '../models/chat_message.dart';

const String _kUrl = 'https://ce.a2ne.com';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textCtl = TextEditingController();
  final List<ChatMessage> _messages = [];
  XFile? _selected;
  Uint8List? _resultBytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _messages.add(ChatMessage(text: '欢迎使用AI修图！\n\n示例指令：\n• 把背景换成海边\n• 帮我去掉水印\n• 把文字\'你好\'改成\'再见\'\n• 给我加个复古滤镜\n• 把这张图抠出来', isUser: false));
  }

  void _pickImage() async {
    if (_busy) return;
    try {
      final p = ImagePicker();
      final f = await p.pickImage(source: ImageSource.gallery);
      if (f != null) {
        setState(() => _selected = f);
        _messages.add(ChatMessage(text: '已选择图片，请输入修图需求', isUser: false));
      }
    } catch (e) {
      setState(() => _messages.add(ChatMessage(text: '❌ 选图失败: $e', isUser: false)));
    }
  }

  Future<void> _send() async {
    if (_busy) return;
    final text = _textCtl.text.trim();
    if (text.isEmpty) return;
    if (_selected == null) { _messages.add(const ChatMessage(text: '请先选择一张图片', isUser: false, isError: true)); return; }

    setState(() { _busy = true; _textCtl.clear(); _resultBytes = null; });
    _messages.add(ChatMessage(text: text, isUser: true));
    _messages.add(const ChatMessage(text: '⏳ 美图API处理中...', isUser: false));
    _scrollToBottom();

    try {
      final bytes = await _selected!.readAsBytes();
      final uri = Uri.parse('$_kUrl/api/edit');

      final req = http.MultipartRequest('POST', uri);
      req.fields['text'] = text;
      req.files.add(http.MultipartFile.fromBytes('image', bytes, filename: _selected!.name));

      final streamed = await req.send().timeout(const Duration(seconds: 120));
      final resp = await http.Response.fromStream(streamed);

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final resultUrl = data['result_image_url'];
        final toolUsed = data['tool_used'] ?? 'unknown';
        final creditInfo = data['credit_consumed'] != null ? ' (消耗${data['credit_consumed']}积分，剩余${data['credit_remaining']})' : '';

        if (resultUrl != null) {
          final imgResp = await http.get(Uri.parse('$_kUrl$resultUrl')).timeout(const Duration(seconds: 30));
          if (imgResp.statusCode == 200) {
            setState(() {
              _messages.removeLast();
              _messages.add(ChatMessage(text: '✅ 处理完成$creditInfo\n工具: $toolUsed', isUser: false));
              _resultBytes = imgResp.bodyBytes;
            });
          } else {
            setState(() {
              _messages.removeLast();
              _messages.add(ChatMessage(text: '✅ 处理完成，但获取结果图片失败 (HTTP ${imgResp.statusCode})', isUser: false));
            });
          }
        } else {
          setState(() {
            _messages.removeLast();
            _messages.add(ChatMessage(text: '✅ 处理完成$creditInfo\n${jsonEncode(data['result_data'] ?? data).toString().substring(0, 200)}', isUser: false));
          });
        }
      } else {
        final body = resp.body;
        String detail;
        try { final j = jsonDecode(body); detail = j['error'] ?? j.toString(); } catch (_) { detail = body.length > 300 ? body.substring(0, 300) : body; }
        setState(() {
          _messages.removeLast();
          _messages.add(ChatMessage(text: '❌ 处理失败 (HTTP ${resp.statusCode}): $detail', isUser: false, isError: true));
        });
      }
    } catch (e) {
      setState(() {
        _messages.removeLast();
        _messages.add(ChatMessage(text: '❌ 网络错误: $e', isUser: false, isError: true));
      });
    } finally {
      setState(() => _busy = false);
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() { _textCtl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(children: [
      Expanded(child: ListView.builder(
        padding: const EdgeInsets.all(8), itemCount: _messages.length,
        itemBuilder: (_, i) {
          final m = _messages[i];
          final align = m.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
          final bg = m.isUser ? t.colorScheme.primaryContainer : (m.isError ? Colors.red.shade50 : t.colorScheme.surfaceVariant);
          final fg = m.isUser ? t.colorScheme.onPrimaryContainer : t.colorScheme.onSurfaceVariant;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(crossAxisAlignment: align, children: [
              if (m.isUser) const SizedBox(height: 4),
              Container(
                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16).copyWith(
                  bottomLeft: m.isUser ? const Radius.circular(16) : Radius.zero,
                  bottomRight: m.isUser ? Radius.zero : const Radius.circular(16))),
                child: Text(m.text, style: TextStyle(color: fg, fontSize: 15))),
            ]));
        })),
      if (_resultBytes != null) GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: const Text('修图结果')),
          body: Center(child: InteractiveViewer(child: Image.memory(_resultBytes!, fit: BoxFit.contain)))))),
        child: Container(height: 120, width: double.infinity, margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), image: DecorationImage(image: MemoryImage(_resultBytes!), fit: BoxFit.contain))),
      ),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.add_photo_alternate_outlined), onPressed: _busy ? null : _pickImage, toolTip: '选择图片'),
          Expanded(child: TextField(
            controller: _textCtl,
            decoration: InputDecoration(
                hintText: _selected != null ? '输入修图需求...' : '先选图片，再输入需求...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                filled: true, fillColor: t.colorScheme.surfaceVariant, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
            textInputAction: TextInputAction.send, onSubmitted: (_) => _send(), maxLines: 3, minLines: 1)),
          const SizedBox(width: 4),
          IconButton.filled(icon: const Icon(Icons.send_rounded), color: t.colorScheme.onPrimary, onPressed: _busy ? null : _send),
        ]),
      ),
    ]);
  }
}
