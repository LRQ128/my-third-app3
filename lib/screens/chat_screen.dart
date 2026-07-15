import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import '../models/chat_message.dart';

// Zeabur backend – connect via IP directly (bypass system DNS),
// use hostName for TLS SNI so Zeabur routes to our service.
const String _kDomain = 'my-third-app3.zeabur.app';
const String _kIp    = '43.131.228.126';
const int    _kPort  = 443;

/// Parse HTTP status from raw response bytes.
int _httpStatus(List<int> raw) {
  for (int i = 0; i < raw.length - 3; i++) {
    if (raw[i]==13 && raw[i+1]==10 && raw[i+2]==13 && raw[i+3]==10) {
      final h = utf8.decode(raw.sublist(0, i));
      final p = h.split('\r\n')[0].split(' ');
      return p.length > 1 ? int.tryParse(p[1]) ?? 500 : 500;
    }
  }
  return 500;
}

/// Split HTTP body from raw response bytes.
List<int> _httpBody(List<int> raw) {
  for (int i = 0; i < raw.length - 3; i++) {
    if (raw[i]==13 && raw[i+1]==10 && raw[i+2]==13 && raw[i+3]==10) return raw.sublist(i + 4);
  }
  return [];
}

/// POST multipart/form-data via raw TLS socket (bypasses DNS entirely).
Future<Map<String, dynamic>> _post(String path, String text, File? img) async {
  final bd = 'BZ${DateTime.now().millisecondsSinceEpoch}Z';
  final buf = <int>[];
  void w(String s) => buf.addAll(utf8.encode(s));

  w('--$bd\r\nContent-Disposition: form-data; name="text"\r\n\r\n$text\r\n');
  if (img != null && img.existsSync()) {
    final ext = img.path.endsWith('.png') ? 'png' : 'jpeg';
    final d = await img.readAsBytes();
    w('--$bd\r\nContent-Disposition: form-data; name="image"; filename="image.$ext"\r\nContent-Type: image/$ext\r\n\r\n');
    buf.addAll(d);
    w('\r\n');
  }
  w('--$bd--\r\n');

  // Use hostName for TLS SNI (NOT 'host' – that's the wrong param name in 3.22.x)
  final s = await SecureSocket.connect(
    _kIp, _kPort,
    hostName: _kDomain,
    timeout: const Duration(seconds: 15),
  );
  try {
    s.add(utf8.encode('POST $path HTTP/1.1\r\nHost: $_kDomain\r\nContent-Type: multipart/form-data; boundary=$bd\r\nContent-Length: ${buf.length}\r\nConnection: close\r\n\r\n'));
    s.add(buf);
    await s.flush();

    final raw = <int>[];
    await for (final c in s) { raw.addAll(c); }
    if (_httpStatus(raw) != 200) return {'error': 'HTTP ${_httpStatus(raw)}'};
    return jsonDecode(utf8.decode(_httpBody(raw))) as Map<String, dynamic>;
  } finally { s.close(); }
}

/// GET raw bytes from a path on the Zeabur server (bypasses DNS).
Future<Uint8List> _getBytes(String path) async {
  final s = await SecureSocket.connect(
    _kIp, _kPort,
    hostName: _kDomain,
    timeout: const Duration(seconds: 15),
  );
  try {
    s.add(utf8.encode('GET $path HTTP/1.1\r\nHost: $_kDomain\r\nConnection: close\r\n\r\n'));
    await s.flush();

    final raw = <int>[];
    await for (final c in s) { raw.addAll(c); }
    return Uint8List.fromList(_httpBody(raw));
  } finally { s.close(); }
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
    _txt.clear(); _scroll(); await _proc(t);
    setState(() { _pending = null; _busy = false; });
  }

  Future<void> _proc(String text) async {
    try {
      setState(() { _msgs.add(ChatMessage(text: '⏳ 正在调用美图API处理，请稍候...', isUser: false, time: DateTime.now(), isLoading: true)); });
      _scroll();

      final data = await _post('/api/edit', text, _pending);
      if (data.containsKey('error')) { _replace('❌ 处理失败：${data['error']}'); return; }

      final exp = data['explanation'] ?? '处理完成';
      final rp = data['result_image_url'];
      final tu = data['tool_used'];
      final cc = data['credit_consumed'];
      final cr = data['credit_remaining'];

      String r = '✅ $exp\n\n🔧 使用工具：$tu\n';
      if (cc != null) r += '💳 消耗积分：$cc\n';
      if (cr != null) r += '📊 剩余积分：$cr';

      if (rp != null && rp is String) {
        final bytes = await _getBytes(rp);
        if (bytes.isNotEmpty) {
          setState(() => _resultBytes = bytes);
          _replace(r);
        } else {
          _replace('$r\n\n⚠️ 结果图片下载失败');
        }
      } else {
        _replace('$r\n\n⚠️ 未返回处理结果图片');
      }
    } catch (e) {
      _replace('❌ 网络错误：$e');
    }
    _scroll();
  }

  void _replace(String t) {
    setState(() {
      if (_msgs.isNotEmpty && _msgs.last.isLoading) _msgs.removeLast();
      _msgs.add(ChatMessage(text: t, isUser: false, time: DateTime.now()));
    });
  }

  void _err(String m) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  @override
  void dispose() { _txt.dispose(); _scrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext c) {
    final t = Theme.of(c);
    return Scaffold(
      appBar: AppBar(title: const Text('AI修图'), centerTitle: true, actions: [_pending != null ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _pending = null)) : const SizedBox.shrink()]),
      body: Column(children: [
        Expanded(child: _msgs.isEmpty ? const Center(child: Text('来开始修图吧！')) : ListView.builder(controller: _scrl, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), itemCount: _msgs.length, itemBuilder: (_, i) => _bubble(_msgs[i], t))),
        if (_pending != null) _preview(),
        _input(t),
      ]),
    );
  }

  Widget _bubble(ChatMessage m, ThemeData t) {
    final u = m.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: u ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
        if (u && m.imagePath != null)
          Padding(padding: const EdgeInsets.only(bottom: 4), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(m.imagePath!), width: 200, height: 200, fit: BoxFit.cover))),
        if (!u && _resultBytes != null)
          Padding(padding: const EdgeInsets.only(bottom: 4), child: InkWell(
              onTap: () => _full(),
              child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_resultBytes!, width: 250, height: 250, fit: BoxFit.contain)))),
        if (m.isLoading)
          const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
        if (m.text.isNotEmpty)
          Container(constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: u ? t.colorScheme.primary : t.colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(18).copyWith(bottomLeft: u ? const Radius.circular(18) : const Radius.circular(4), bottomRight: u ? const Radius.circular(4) : const Radius.circular(18))),
              child: Text(m.text, style: TextStyle(color: u ? t.colorScheme.onPrimary : t.colorScheme.onSurface, fontSize: 15))),
        Padding(padding: const EdgeInsets.only(top: 2, left: 8, right: 8), child: Text('${m.time.hour.toString().padLeft(2, '0')}:${m.time.minute.toString().padLeft(2, '0')}', style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 11))),
      ]),
    );
  }

  Widget _preview() {
    return Container(height: 80, color: Colors.grey[100], padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(_pending!, width: 60, height: 60, fit: BoxFit.cover)),
          const SizedBox(width: 12),
          Expanded(child: Text('已选择图片，输入修图需求后发送', style: TextStyle(color: Colors.grey[600], fontSize: 13))),
        ]));
  }

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
