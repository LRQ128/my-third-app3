const express = require('express');
const multer = require('multer');
const { execSync, exec } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const app = express();
const PORT = process.env.PORT || 5078;

// Temp dirs
const UPLOAD_DIR = path.join(os.tmpdir(), 'xiutu_uploads');
const OUTPUT_DIR = path.join(os.tmpdir(), 'xiutu_outputs');
fs.mkdirSync(UPLOAD_DIR, { recursive: true });
fs.mkdirSync(OUTPUT_DIR, { recursive: true });

// Multer config
const storage = multer.diskStorage({
  destination: UPLOAD_DIR,
  filename: (req, file, cb) => {
    cb(null, Date.now() + '-' + Math.random().toString(36).slice(2) + path.extname(file.originalname || '.jpg'));
  }
});
const upload = multer({ storage, limits: { fileSize: 20 * 1024 * 1024 } });

// Find meitu CLI (graceful)
let MEITU_CLI = process.env.MEITU_CLI_PATH || 'npx meitu';
try {
  const found = execSync('which meitu 2>/dev/null || echo ""', { encoding: 'utf8', timeout: 5000 }).trim();
  if (found) MEITU_CLI = found;
} catch {}
console.log('Meitu CLI:', MEITU_CLI);

// Find Python
const PYTHON = process.env.PYTHON_PATH || 'python3';

// ===================== Free Tool Definitions =====================
const FREE_TOOLS = {
  'cutout':       { label: '抠图',       needsText: false, hasSourceTarget: false },
  'text-replace': { label: '改字',       needsText: true,  hasSourceTarget: true },
  'denoise':      { label: '去噪',       needsText: false, hasSourceTarget: false },
  'enhance':      { label: '暗部增强',   needsText: false, hasSourceTarget: false },
  'superres':     { label: '超清',       needsText: false, hasSourceTarget: false },
  'grayscale':    { label: '黑白',       needsText: false, hasSourceTarget: false },
  'sepia':        { label: '复古',       needsText: false, hasSourceTarget: false },
  'rotate':       { label: '旋转',       needsText: false, hasSourceTarget: false },
  'blur':         { label: '模糊',       needsText: false, hasSourceTarget: false },
};

// ===================== Helper: extract old/new text =====================
function extractTextReplace(text) {
  const patterns = [
    /(?:把|将)?(.+?)(?:改成|改为|替换为)(.+?)(?:$|的|，|。)/,
    /(?:改成|改为|替换为)(.+?)(?:$|的|，|。)/,
  ];
  for (const pat of patterns) {
    const m = text.match(pat);
    if (m) {
      if (m[2] !== undefined) return [m[1].trim(), m[2].trim()];
      return ['', m[1].trim()];
    }
  }
  const sep = text.includes('改成') ? '改成' : (text.includes('改为') ? '改为' : null);
  if (sep) {
    const parts = text.split(sep);
    if (parts.length === 2) return [parts[0].trim(), parts[1].trim()];
  }
  return ['', ''];
}

// ===================== Routes =====================

// Health
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', mode: 'dual', freeTools: Object.keys(FREE_TOOLS) });
});

// Credit
app.get('/api/credit', (req, res) => {
  try {
    const out = execSync(`${MEITU_CLI} account overview --json 2>/dev/null`, { encoding: 'utf8', timeout: 30000 });
    res.json(JSON.parse(out));
  } catch (e) {
    res.json({ error: e.message });
  }
});

// Edit image - dual mode (free / meitu)
app.post('/api/edit', upload.single('image'), async (req, res) => {
  try {
    const file = req.file;
    const userText = req.body.text || '';
    const mode = (req.body.mode || 'free').toLowerCase();
    const tool = (req.body.tool || '').toLowerCase();

    if (!file) return res.status(400).json({ error: '请选择图片' });
    if (mode === 'free' && !tool) return res.status(400).json({ error: '请选择免费工具' });

    const ext = path.extname(file.originalname || '.jpg') || '.jpg';
    const outFilename = Date.now() + '-' + Math.random().toString(36).slice(2) + ext;
    const outPath = path.join(OUTPUT_DIR, outFilename);

    console.log(`Mode: ${mode}, Tool: ${tool}, Image: ${file.filename}, Text: "${userText}"`);

    if (mode === 'free') {
      await processFree(req, res, file, userText, tool, outPath, outFilename);
    } else {
      await processMeitu(req, res, file, userText, tool, outPath, outFilename);
    }
  } catch (error) {
    return res.status(500).json({ error: '处理失败: ' + error.message });
  }
});

// ===================== Free Processing =====================
async function processFree(req, res, file, userText, tool, outPath, outFilename) {
  const toolInfo = FREE_TOOLS[tool];
  if (!toolInfo) {
    return res.status(400).json({ error: `未知工具: ${tool}` });
  }

  let args = [tool, file.path, outPath];

  if (tool === 'text-replace') {
    const [source, target] = extractTextReplace(userText);
    if (source) {
      args.push(source, target);
    } else if (userText) {
      // User typed something, split by space
      const parts = userText.split(/\s+/);
      args.push(parts[0] || '');
      args.push(parts[1] || parts[0] || '');
    } else {
      args.push('', '');
    }
  }

  const pythonScript = path.join(__dirname, 'free_tools.py');
  const cmd = `${PYTHON} "${pythonScript}" ${args.map(a => `"${a.replace(/"/g, '\\"')}"`).join(' ')}`;

  console.log(`Free tool cmd: ${cmd}`);

  exec(cmd, { timeout: 60000, maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
    // Cleanup uploaded file
    try { fs.unlinkSync(file.path); } catch {}

    if (err) {
      console.error('Free tool error:', stderr || stdout);
      return res.status(500).json({ error: '免费工具处理失败', tool_used: `free/${tool}` });
    }

    let result;
    try { result = JSON.parse(stdout); } catch {
      return res.status(500).json({ error: '工具输出解析失败', raw: stdout.slice(0, 200) });
    }

    if (result.error) {
      return res.status(500).json({ error: result.error, tool_used: `free/${tool}` });
    }

    const resultUrl = fs.existsSync(outPath) ? `/api/result/${outFilename}` : null;

    return res.json({
      success: true,
      mode: 'free',
      explanation: result.explanation || `免费${toolInfo.label}完成`,
      tool_used: `free/${tool}`,
      result_image_url: resultUrl,
      credit_consumed: 0,
      credit_remaining: '∞ (免费)',
    });
  });
}

// ===================== Meitu Processing =====================
async function processMeitu(req, res, file, userText, tool, outPath, outFilename) {
  const outputId = Date.now() + '-' + Math.random().toString(36).slice(2);
  const downloadDir = path.join(OUTPUT_DIR, outputId);
  fs.mkdirSync(downloadDir, { recursive: true });

  // Get pre-credit
  let preCredit = null;
  try {
    const out = execSync(`${MEITU_CLI} account overview --json 2>/dev/null`, { encoding: 'utf8', timeout: 10000 });
    preCredit = JSON.parse(out);
  } catch {}

  // Determine meitu tool
  let toolName = tool || 'image-edit';
  if (!tool) {
    const t = userText.toLowerCase();
    if (t.includes('背景') || t.includes('background')) {
      toolName = t.includes('去除') || t.includes('去掉') ? 'image-cutout' : 'image-background-replace';
    } else if (t.includes('抠图') || t.includes('去背景') || t.includes('透明')) {
      toolName = 'image-cutout';
    } else if (t.includes('去水印') || t.includes('去除') || t.includes('消除')) {
      toolName = 'image-element-remove';
    } else if (t.includes('改字') || t.includes('改文字') || t.includes('改成') || t.includes('改为')) {
      toolName = 'image-text-replace';
    } else {
      toolName = 'image-edit';
    }
  }

  const paramFlag = ['image-background-replace', 'image-cutout', 'image-element-remove', 'image-text-replace'].includes(toolName)
    ? '--image_url' : '--image_list';

  let prompt = userText;
  let extraParams = '';
  if (toolName === 'image-text-replace') {
    const [source, target] = extractTextReplace(userText);
    if (source && target) {
      extraParams = `--source_words "${source.replace(/"/g, '\\"')}" --target_words "${target.replace(/"/g, '\\"')}"`;
      prompt = '';
    }
  }

  const cmd = `${MEITU_CLI} ${toolName.replace(/_/g, '-')} ${paramFlag} "${file.path}" ${prompt ? `--prompt "${prompt.replace(/"/g, '\\"')}"` : ''} ${extraParams} --download-dir "${downloadDir}" --json 2>&1`;

  console.log(`Meitu cmd: ${cmd.slice(0, 200)}...`);

  exec(cmd, { timeout: 120000, maxBuffer: 50 * 1024 * 1024 }, (err, stdout, stderr) => {
    // Get post-credit
    let postCredit = null;
    try {
      const out = execSync(`${MEITU_CLI} account overview --json 2>/dev/null`, { encoding: 'utf8', timeout: 10000 });
      postCredit = JSON.parse(out);
    } catch {}

    try { fs.unlinkSync(file.path); } catch {}

    if (err) {
      console.error('Meitu error:', stderr || stdout);
      return res.status(500).json({ error: '美图API失败: ' + (stderr || stdout || err.message).slice(0, 500), tool_used: toolName });
    }

    let resultUrl = null;
    try {
      const files = fs.readdirSync(downloadDir);
      if (files.length > 0) {
        const srcPath = path.join(downloadDir, files[0]);
        fs.copyFileSync(srcPath, outPath);
        resultUrl = `/api/result/${outFilename}`;
      }
    } catch {}

    let resultData = {};
    try { resultData = JSON.parse(stdout); } catch { resultData = { raw: stdout.slice(0, 500) }; }

    let creditConsumed = null, creditRemaining = null;
    try {
      if (preCredit && postCredit) {
        const pre = preCredit.data?.credits_balance || 0;
        const post = postCredit.data?.credits_balance || 0;
        creditConsumed = Math.max(0, pre - post);
        creditRemaining = post;
      }
    } catch {}

    res.json({
      success: true,
      mode: 'meitu',
      tool_used: toolName,
      result_image_url: resultUrl,
      result_data: resultData,
      credit_consumed: creditConsumed,
      credit_remaining: creditRemaining,
    });
  });
}

// Serve result images (flat directory)
app.get('/api/result/:filename', (req, res) => {
  const filePath = path.join(OUTPUT_DIR, req.params.filename);
  if (fs.existsSync(filePath)) {
    res.sendFile(filePath);
  } else {
    res.status(404).json({ error: 'File not found' });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`修图后端启动 (端口 ${PORT}) - 双模式: 免费 + 美图`);
});
