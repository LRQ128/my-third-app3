import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../models/chat_message.dart';

const String _kBase = 'https://ce.a2ne.com';

/// Test if we can make ANY network request (baidu always works in China).
Future<String> _testNetwork() async {
  try {
    final res = await http.get(Uri.parse('https://www.baidu.com'))
        .timeout(const Duration(seconds: 10));
    return '百度: HTTP ${res.statusCode} ✅';
  } catch (e) {
    return '百度: $e ❌';
  }
}

Future<Map<String, dynamic>> _post(String path, String text, File? img) async {
  final uri = Uri.parse('$_kBase$path');
  final req = http.MultipartRequest('POST', uri)
    ..fields['text'] = text;
  if (img != null && img.existsSync()) {
    req.files.add(await http.MultipartFile.fromPath('image', img.path));
  }
  final res = await req.send().timeout(const Duration(seconds: 60));
  final body = await res.stream.bytesToString();
  if (res.statusCode != 200) return {'error': 'HTTP ${res.statusCode}: $body'};
  return jsonDecode(body) as Map<String, dynamic>;
}

Future<Uint8List> _getBytes(String url) async {
  final uri = Uri.parse(url.startsWith('http') ? url : '$_kBase$url');
  final res = await http.get(uri).timeout(const Duration(seconds: 60));
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return res.bodyBytes;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<ChatMessage> _msgs = [];
  final TextEditingController _txt = TextEditingController();
  final ScrollController _scrl = ScrollController();
  final ImagePicker _picker = ImagePicker();
  File? _pending;
  bool _busy = false;
  Uint8List? _resultBytes;

  @override
  void initState() { super.initState(); _welcome(); }
  void _welcome() { setState(() { _msgs.add(ChatMessage(text: '👋 你好！发一张图片和你的修图需求给我，我来帮你处理！\n\n例如：\n• 「把背景换成海边」\n• 「帮我去掉水印」\n• 「把文字\'你好\'改成\'再见\'」\n• 「给我加个复古滤镜」\n• 「把这张图抠出来」', isUser: false, time: DateTime.now())); }); }
  void _scroll() { WidgetsBinding.instance.addPostFrameCallback((_) { if (_scrl.hasClients) _scrl.animateTo(_scrl.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut); }); }

  Future<void> _pick() async {
    if (_busy) return;
    try {
      final i = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1920, maxHeight: 1920, imageQuality: 90);
      if (i != null) { setState(() => _pending = File(i.path)); _msgs.add(ChatMessage(text: '已选择图片，请输入修图需求', isUser: false, time: DateTime.now(), imagePath: i.path)); _scroll(); }
    } catch (_) { _err('选择图片失败'); }
  }

  Future<void> _send() async {
    final t = _txt.text.trim();
    if (t.isEmpty && _pending == null) return;
    setState(() { _busy = true; _msgs.add(ChatMessage(text: t, isUser: true, time: DateTime.now(), imagePath: _pending?.path)); });
    _txt.clear(); _scroll();
    
    // Test network first, then process image
    if (_pending != null) {
      final netTest = await _testNetwork();
      setState(() { _msgs.add(ChatMessage(text: '📡 网络诊断：\n$netTest', isUser: false, time: DateTime.now())); });
      _scroll();
      
      // Then try our server
      try {
        setState(() { _msgs.add(ChatMessage(text: '⏳ 正在连接到 ce.a2ne.com...', isUser: false, time: DateTime.now(), isLoading: true)); });
        _scroll();
        
        final uri = Uri.parse('$_kBase/api/edit');
        final req = http.MultipartRequest('POST', uri)
          ..fields['text'] = t;
        if (_pending != null && _pending!.existsSync()) {
          req.files.add(await http.MultipartFile.fromPath('image', _pending!.path));
        }
        final res = await req.send().timeout(const Duration(seconds: 30));
        final body = await res.stream.bytesToString();
        
        _replace('📡 后端连接：\nHTTP ${res.statusCode}\n响应：${body.substring(0, body.length.clamp(0, 200))}');
      } catch (e) {
        _replace('📡 后端连接：\n❌ $e');
      }
    } else {
      setState(() { _msgs.add(ChatMessage(text: t, isUser: true, time: DateTime.now())); });
    }
    setState(() { _pending = null; _busy = false; });
  }

  void _replace(String t) { setState(() { if (_msgs.isNotEmpty && _msgs.last.isLoading) _msgs.removeLast(); _msgs.add(ChatMessage(text: t, isUser: false, time: DateTime.now())); }); }
  void _err(String m) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  @override
  void dispose() { _txt.dispose(); _scrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('AI修图'), centerTitle: true, actions: [_pending != null ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _pending = null)) : const SizedBox.shrink()]),
      body: Column(children: [
        Expanded(child: _msgs.isEmpty ? const Center(child: Text('来开始修图吧！')) : ListView.builder(controller: _scrl, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), itemCount: _msgs.length, itemBuilder: (ctx, i) => _bubble(_msgs[i], t, ctx))),
        if (_pending != null) _preview(),
        _input(t),
      ]),
    );
  }

  Widget _bubble(ChatMessage m, ThemeData t, BuildContext ctx) {
    final u = m.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: u ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
        if (u && m.imagePath != null)
          Padding(padding: const EdgeInsets.only(bottom: 4), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(m.imagePath!), width: 200, height: 200, fit: BoxFit.cover))),
        if (!u && _resultBytes != null)
          Padding(padding: const EdgeInsets.only(bottom: 4), child: InkWell(onTap: () => _full(),
              child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_resultBytes!, width: 250, height: 250, fit: BoxFit.contain)))),
        if (m.isLoading) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
        if (m.text.isNotEmpty)
          Container(constraints: BoxConstraints(maxWidth: MediaQuery.of(ctx).size.width * 0.75), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: u ? t.colorScheme.primary : t.colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(18).copyWith(bottomLeft: u ? const Radius.circular(18) : const Radius.circular(4), bottomRight: u ? const Radius.circular(4) : const Radius.circular(18))),
              child: Text(m.text, style: TextStyle(color: u ? t.colorScheme.onPrimary : t.colorScheme.onSurface, fontSize: 15))),
        Padding(padding: const EdgeInsets.only(top: 2, left: 8, right: 8), child: Text('${m.time.hour.toString().padLeft(2, '0')}:${m.time.minute.toString().padLeft(2, '0')}', style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 11))),
      ]),
    );
  }

  Widget _preview() { return Container(height: 80, color: Colors.grey[100], padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Row(children: [
    ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(_pending!, width: 60, height: 60, fit: BoxFit.cover)),
    const SizedBox(width: 12),
    Expanded(child: Text('已选择图片，输入修图需求后发送', style: TextStyle(color: Colors.grey[600], fontSize: 13))),
  ])); }

  Widget _input(ThemeData t) {
    return Container(
      padding: EdgeInsets.only(left: 8, right: 8, top: 8, bottom: MediaQuery.of(context).padding.bottom + 8),
      decoration: BoxDecoration(color: t.colorScheme.surface, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 4, offset: const Offset(0, -1))]),
      child: Row(children: [
        IconButton(icon: const Icon(Icons.image_outlined), color: t.colorScheme.primary, onPressed: _busy ? null : _pick),
        Expanded(child: TextField(controller: _txt, enabled: !_busy,
            decoration: InputDecoration(hintText: _pending != null ? '输入修图需求...' : '先选图片，再输入需求...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                filled: true, fillColor: t.colorScheme.surfaceVariant, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
            textInputAction: TextInputAction.send, onSubmitted: (_) => _send(), maxLines: 3, minLines: 1)),
        const SizedBox(width: 4),
        IconButton.filled(icon: const Icon(Icons.send_rounded), color: t.colorScheme.onPrimary, onPressed: _busy ? null : _send),
      ]),
    );
  }

  void _full() {
    if (_resultBytes == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
        backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: const Text('修图结果')),
        body: Center(child: InteractiveViewer(child: Image.memory(_resultBytes!, fit: BoxFit.contain))))));
  }
}
