import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/chat_message.dart';

const String _kUrl = 'https://ce.a2ne.com';

// ========== Chat persistence ==========
class _Store {
  static String? _base;

  static Future<String> get _dir async {
    if (_base == null) {
      final d = await getApplicationDocumentsDirectory();
      final b = Directory('${d.path}/xiutu_data');
      if (!b.existsSync()) b.createSync(recursive: true);
      _base = b.path;
    }
    return _base!;
  }

  static Future<List<ChatMessage>> load() async {
    final f = File('${await _dir}/msgs.json');
    if (!f.existsSync()) return [];
    try {
      return (jsonDecode(await f.readAsString()) as List).map((e) =>
        ChatMessage(
          text: e['t'] ?? '',
          isUser: e['u'] ?? false,
          time: DateTime.parse(e['ts']),
          imagePath: e['ip'],
          resultImageUrl: e['rp'],
        )).toList();
    } catch (_) { return []; }
  }

  static Future<void> save(List<ChatMessage> msgs) async {
    await File('${await _dir}/msgs.json').writeAsString(jsonEncode(
      msgs.map((m) => {
        't': m.text, 'u': m.isUser, 'ts': m.time.toIso8601String(),
        'ip': m.imagePath, 'rp': m.resultImageUrl,
      }).toList()));
  }

  static Future<String> saveImg(Uint8List bytes, String prefix) async {
    final d = Directory('${await _dir}/$prefix');
    if (!d.existsSync()) d.createSync();
    final fn = '${prefix}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File('${d.path}/$fn').writeAsBytes(bytes, flush: true);
    return '${d.path}/$fn';
  }

  static Future<String> copyImg(File src, String prefix) async {
    final d = Directory('${await _dir}/$prefix');
    if (!d.existsSync()) d.createSync();
    final fn = '${prefix}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final dest = '${d.path}/$fn';
    await src.copy(dest);
    return dest;
  }
}

// ========== HTTP client with auto-retry on errno=103 ==========
Future<Map<String, dynamic>> _post(String path, String text, File img) async {
  int attempt = 0;

  while (true) {
    final client = HttpClient()
      ..badCertificateCallback = (_) => true;
    try {
      final uri = Uri.parse('$_kUrl$path');
      final req = await client.postUrl(uri);

      final bd = 'BZ${DateTime.now().millisecondsSinceEpoch}Z';
      final buf = <int>[];
      void w(String s) => buf.addAll(utf8.encode(s));
      w('--$bd\r\nContent-Disposition: form-data; name="text"\r\n\r\n$text\r\n');
      final ext = img.path.endsWith('.png') ? 'png' : 'jpeg';
      final d = await img.readAsBytes();
      w('--$bd\r\nContent-Disposition: form-data; name="image"; filename="image.$ext"\r\nContent-Type: image/$ext\r\n\r\n');
      buf.addAll(d);
      w('\r\n--$bd--\r\n');

      req.headers.set('Content-Type', 'multipart/form-data; boundary=$bd');
      req.headers.set('Content-Length', buf.length.toString());
      req.add(buf);

      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();

      if (resp.statusCode == 200) return jsonDecode(body) as Map<String, dynamic>;

      String detail;
      try { final j = jsonDecode(body); detail = j['error'] ?? j.toString(); }
      catch (_) { detail = body.length > 300 ? body.substring(0, 300) : body; }
      return {'error': 'HTTP ${resp.statusCode}: $detail'};

    } on SocketException catch (e) {
      // errno=103 = Software caused connection abort (app switched to background)
      if (e.osError?.errorCode == 103 && attempt < 1) {
        attempt++;
        await Future.delayed(const Duration(seconds: 1));
        continue; // retry once
      }
      rethrow;
    } finally { client.close(); }
  }
}

Future<Uint8List> _get(String path) async {
  final client = HttpClient()
    ..badCertificateCallback = (_) => true;
  try {
    final uri = Uri.parse('$_kUrl$path');
    final req = await client.getUrl(uri);
    final resp = await req.close();
    final bytes = <int>[];
    await for (final c in resp) { bytes.addAll(c); }
    return Uint8List.fromList(bytes);
  } finally { client.close(); }
}

// ========== Chat screen ==========
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _txt = TextEditingController();
  List<ChatMessage> _msgs = [];
  XFile? _selected;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final saved = await _Store.load();
    if (saved.isNotEmpty) {
      setState(() => _msgs = saved);
    } else {
      setState(() => _msgs = [ChatMessage(
        text: '欢迎使用AI修图！\n\n示例指令：\n• 把背景换成海边\n• 帮我去掉水印\n• 贺泽两字改为天天\n• 图片清晰度调高\n• 把这张图抠出来',
        isUser: false,
        time: DateTime.now())]);  
    }
  }

  Future<void> _pick() async {
    if (_busy) return;
    try {
      final f = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (f != null) {
        setState(() => _selected = f);
      }
    } catch (_) { _addMsg('❌ 选图失败', false); _persist(); }
  }

  Future<void> _send() async {
    if (_busy) return;
    final t = _txt.text.trim();
    if (t.isEmpty || _selected == null) return;

    setState(() { _busy = true; _txt.clear(); });
    _addMsg(t, true);
    _addMsg('⏳ 美图API处理中...', false);
    _persist();

    try {
      // Save user image locally for persistence
      final imgPath = await _Store.copyImg(File(_selected!.path), 'picked');
      
      // Re-add user message with image path (replace previous text-only entry)
      setState(() {
        _msgs.removeWhere((m) => m.text == t && m.isUser);
        _msgs.add(ChatMessage(text: t, isUser: true, time: DateTime.now(), imagePath: imgPath));
      });

      final data = await _post('/api/edit', t, File(_selected!.path));
      setState(() => _msgs.removeWhere((m) => m.text.startsWith('⏳')));

      if (data.containsKey('error')) {
        _addMsg('❌ ${data['error']}', false);
        _persist();
        return;
      }

      final rp = data['result_image_url'];
      final tu = data['tool_used'];
      final cc = data['credit_consumed'];
      final cr = data['credit_remaining'];

      String r = '✅ 处理完成';
      if (tu != null) r += '\n🔧 工具：$tu';
      if (cc != null) r += '\n💳 消耗${cc}积分，剩余${cr}';

      if (rp != null && rp is String) {
        try {
          final bytes = await _get(rp);
          if (bytes.isNotEmpty) {
            final localPath = await _Store.saveImg(bytes, 'result');
            _addMsg(ChatMessage(text: r, isUser: false, time: DateTime.now(), resultImageUrl: localPath));
          } else {
            _addMsg('$r\n⚠️ 结果图片为空', false);
          }
        } catch (_) {
          _addMsg('$r\n⚠️ 结果图片下载失败', false);
        }
      } else {
        _addMsg(r, false);
      }
      _persist();
    } catch (e) {
      setState(() => _msgs.removeWhere((m) => m.text.startsWith('⏳')));
      _addMsg('❌ 网络错误：$e', false);
      _persist();
    } finally {
      setState(() { _busy = false; _selected = null; });
    }
  }

  void _addMsg(dynamic textOrMsg, bool isUser) {
    setState(() {
      if (textOrMsg is String) {
        _msgs.add(ChatMessage(text: textOrMsg, isUser: isUser, time: DateTime.now()));
      } else if (textOrMsg is ChatMessage) {
        _msgs.add(textOrMsg);
      }
    });
  }

  Future<void> _persist() async {
    try { await _Store.save(_msgs); } catch (_) {}
  }

  @override
  void dispose() { _txt.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(children: [
      Expanded(child: ListView.builder(
        padding: const EdgeInsets.all(8), itemCount: _msgs.length,
        itemBuilder: (_, i) => _buildMsg(_msgs[i], t)),
      ),
      if (_selected != null) _preview(),
      Container(padding: const EdgeInsets.all(8),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.add_photo_alternate_outlined), onPressed: _busy ? null : _pick),
          Expanded(child: TextField(controller: _txt, enabled: !_busy,
            decoration: InputDecoration(
              hintText: _selected != null ? '输入修图需求...' : '先选图片，再输入需求...',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              filled: true, fillColor: t.colorScheme.surfaceVariant, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
            textInputAction: TextInputAction.send, onSubmitted: (_) => _send(), maxLines: 2, minLines: 1)),
          const SizedBox(width: 4),
          IconButton.filled(icon: const Icon(Icons.send_rounded), onPressed: _busy ? null : _send),
        ])),
    ]);
  }

  Widget _buildMsg(ChatMessage m, ThemeData t) {
    final u = m.isUser;
    final align = u ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return Padding(padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: align, children: [
        // User-picked image
        if (u && m.imagePath != null)
          Padding(padding: const EdgeInsets.only(bottom: 4),
            child: ClipRRect(borderRadius: BorderRadius.circular(12),
              child: Image.file(File(m.imagePath!), width: 180, height: 180, fit: BoxFit.cover))),
        // Result image
        if (!u && m.resultImageUrl != null)
          Padding(padding: const EdgeInsets.only(bottom: 4),
            child: GestureDetector(
              onTap: () {
                final bytes = File(m.resultImageUrl!).readAsBytesSync();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
                  backgroundColor: Colors.black,
                  appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: const Text('修图结果')),
                  body: Center(child: InteractiveViewer(child: Image.memory(Uint8List.fromList(bytes), fit: BoxFit.contain))))));
              },
              child: ClipRRect(borderRadius: BorderRadius.circular(12),
                child: Image.file(File(m.resultImageUrl!), width: 220, height: 220, fit: BoxFit.contain)),
            )),
        // Text bubble
        if (m.text.isNotEmpty && !m.text.startsWith('⏳'))
          Container(constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: u ? t.colorScheme.primary : t.colorScheme.surfaceVariant,
              borderRadius: BorderRadius.circular(16).copyWith(
                bottomLeft: u ? const Radius.circular(16) : Radius.zero,
                bottomRight: u ? Radius.zero : const Radius.circular(16))),
            child: Text(m.text, style: TextStyle(color: u ? t.colorScheme.onPrimary : t.colorScheme.onSurface, fontSize: 15))),
        if (m.text.startsWith('⏳'))
          const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
        Padding(padding: const EdgeInsets.only(top: 2, left: 8, right: 8),
          child: Text('${m.time.hour.toString().padLeft(2, '0')}:${m.time.minute.toString().padLeft(2, '0')}',
            style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontSize: 11))),
      ]));
  }

  Widget _preview() {
    return Container(height: 72, color: Colors.grey[100], padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(File(_selected!.path), width: 56, height: 56, fit: BoxFit.cover)),
        const SizedBox(width: 12),
        Expanded(child: Text('已选择图片，输入修图需求后发送', style: TextStyle(color: Colors.grey[600], fontSize: 13))),
      ]));
  }
}
