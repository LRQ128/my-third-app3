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

// Multer config - save to UPLOAD_DIR
const storage = multer.diskStorage({
  destination: UPLOAD_DIR,
  filename: (req, file, cb) => {
    cb(null, Date.now() + '-' + Math.random().toString(36).slice(2) + path.extname(file.originalname || '.jpg'));
  }
});
const upload = multer({ storage, limits: { fileSize: 20 * 1024 * 1024 } });

// Find meitu CLI (graceful on startup)
let MEITU_CLI = process.env.MEITU_CLI_PATH || 'npx meitu';
try {
  const found = execSync('which meitu 2>/dev/null || echo ""', { encoding: 'utf8', timeout: 5000 }).trim();
  if (found) MEITU_CLI = found;
} catch {}
console.log('Meitu CLI:', MEITU_CLI);

// Health check
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', meitu_cli: MEITU_CLI });
});

// Check credits
app.get('/api/credit', (req, res) => {
  try {
    const out = execSync(`${MEITU_CLI} account overview --json 2>/dev/null`, { encoding: 'utf8', timeout: 30000 });
    res.json(JSON.parse(out));
  } catch (e) {
    res.json({ error: e.message });
  }
});

// Edit image
app.post('/api/edit', upload.single('image'), async (req, res) => {
  try {
    const file = req.file;
    const userText = req.body.text || '';
    
    if (!file) return res.status(400).json({ error: 'No image' });
    if (!userText) return res.status(400).json({ error: 'No text' });

    const outputId = Date.now() + '-' + Math.random().toString(36).slice(2);
    const downloadDir = path.join(OUTPUT_DIR, outputId);
    fs.mkdirSync(downloadDir, { recursive: true });

    // Get pre-credit
    let preCredit = null;
    try {
      const out = execSync(`${MEITU_CLI} account overview --json 2>/dev/null`, { encoding: 'utf8', timeout: 10000 });
      preCredit = JSON.parse(out);
    } catch {}

    // Classify request - support more Chinese text patterns
    const t = userText.toLowerCase();
    let toolName = 'image-text-replace';

    if (t.includes('背景') || t.includes('background')) {
      toolName = (t.includes('去除') || t.includes('去掉') || t.includes('移除')) ? 'image-cutout' : 'image-background-replace';
    } else if (t.includes('抠图') || t.includes('去背景') || t.includes('透明') || t.includes('cutout') || t.includes('remove background')) {
      toolName = 'image-cutout';
    } else if (t.includes('去水印') || t.includes('去掉') || t.includes('去除') || t.includes('消除') || t.includes('移除')) {
      toolName = 'image-element-remove';
    } else if (t.includes('改字') || t.includes('改文字') || t.includes('替换文字') || t.includes('改成') || t.includes('改为') || t.includes('修改') || t.includes('替换')) {
      toolName = 'image-text-replace';
    } else if (t.includes('滤镜') || t.includes('美化') || t.includes('修图') || t.includes('编辑')) {
      toolName = 'image-edit';
    } else {
      // Default: text replacement (most common use case)
      toolName = 'image-text-replace';
    }

    console.log(`Tool: ${toolName}, Image: ${file.filename}, Prompt: ${userText}`);

    // Determine correct parameter name based on tool
    const toolsRequiringImageUrl = ['image-background-replace', 'image-cutout', 'image-element-remove', 'image-text-replace'];
    const imgParam = toolsRequiringImageUrl.includes(toolName) ? '--image_url' : '--image_list';

    // Call meitu CLI
    const cmd = `${MEITU_CLI} ${toolName.replace(/_/g, '-')} ${imgParam} "${file.path}" --prompt "${userText.replace(/"/g, '\\"')}" --download-dir "${downloadDir}" --json 2>&1`;
    
    exec(cmd, { timeout: 120000, maxBuffer: 50 * 1024 * 1024 }, (err, stdout, stderr) => {
      // Get post-credit
      let postCredit = null;
      try {
        const out = execSync(`${MEITU_CLI} account overview --json 2>/dev/null`, { encoding: 'utf8', timeout: 10000 });
        postCredit = JSON.parse(out);
      } catch {}

      // Cleanup uploaded file
      try { fs.unlinkSync(file.path); } catch {}

      if (err) {
        console.error('Meitu CLI error:', stderr || stdout);
        return res.status(500).json({
          error: '美图API处理失败: ' + (stderr || stdout || err.message).slice(0, 500),
          tool_used: toolName
        });
      }

      // Find result image
      let resultUrl = null;
      try {
        const files = fs.readdirSync(downloadDir);
        if (files.length > 0) {
          resultUrl = `/api/result/${outputId}/${files[0]}`;
        }
      } catch {}

      // Parse result
      let resultData = {};
      try { resultData = JSON.parse(stdout); } catch { resultData = { raw: stdout.slice(0, 500) }; }

      // Credit consumption
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
        tool_used: toolName,
        result_image_url: resultUrl,
        result_data: resultData,
        credit_consumed: creditConsumed,
        credit_remaining: creditRemaining
      });
    });
  } catch (error) {
    return res.status(500).json({ error: '处理失败: ' + error.message });
  }
});

// Serve result images
app.get('/api/result/:outputId/:filename', (req, res) => {
  const filePath = path.join(OUTPUT_DIR, req.params.outputId, req.params.filename);
  if (fs.existsSync(filePath)) {
    res.sendFile(filePath);
  } else {
    res.status(404).json({ error: 'File not found' });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`修图后端启动 (端口 ${PORT})`);
});
