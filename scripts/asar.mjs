#!/usr/bin/env node
/**
 * 极简 asar 读写工具（零依赖）
 *
 * asar 布局（实测确认）：
 *   [0..3]   uint32 = 4
 *   [4..7]   uint32 = headerSize          → 数据区起点 = 8 + headerSize
 *   [8..11]  uint32 = headerSize - 4      （内层 pickle 载荷长度）
 *   [12..15] uint32 = jsonLen             （目录 JSON 字节数）
 *   [16..]   JSON 目录（后面补 0 对齐到 4 字节）
 *   [dataStart..] 各文件数据按目录里的 offset 拼接
 *
 * 本工具读取时用 asar 目录里自带的 SHA-256 做自校验。
 *
 * 用法:
 *   asar.mjs list    <app.asar>
 *   asar.mjs cat     <app.asar> <内部路径>
 *   asar.mjs extract <app.asar> <输出目录> [--exclude 前缀]
 *   asar.mjs verify  <app.asar> [抽样数量]
 */

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

export function openAsar(asarPath) {
  const fd = fs.openSync(asarPath, 'r');
  const h = Buffer.alloc(16);
  fs.readSync(fd, h, 0, 16, 0);
  const headerSize = h.readUInt32LE(4);
  const jsonLen = h.readUInt32LE(12);
  const jb = Buffer.alloc(jsonLen);
  fs.readSync(fd, jb, 0, jsonLen, 16);
  const tree = JSON.parse(jb.toString('utf8'));
  return { fd, tree, jsonLen, dataStart: 8 + headerSize };
}

export function walkAsar(tree) {
  const out = [];
  (function walk(node, prefix) {
    for (const [name, child] of Object.entries(node.files || {})) {
      const p = `${prefix}/${name}`;
      if (child.files) walk(child, p);
      else out.push({ path: p, node: child });
    }
  })(tree, '');
  return out;
}

export function readEntry({ fd, dataStart }, entry) {
  const buf = Buffer.alloc(entry.size);
  fs.readSync(fd, buf, 0, entry.size, dataStart + parseInt(entry.offset, 10));
  return buf;
}

// ---------------- CLI ----------------
// 判断是否为 CLI 直接调用。
//
// 不要写成 `import.meta.url === \`file://${process.argv[1]}\``：
// import.meta.url 会对路径做百分号编码（本仓库路径含中文，会被编码成
// %E6%B8%85%E5%8D%95…），而 argv[1] 是原始路径，两者永不相等 ——
// 结果是脚本静默什么都不做、退出码还是 0（本仓库踩过这个坑）。
// 正确做法是两边都转成真实文件系统路径再比较。
const isMain =
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const [, , cmd, asarPath, arg3, ...rest] = process.argv;
  if (!cmd || !asarPath) {
    console.error('用法: asar.mjs list|cat|extract|verify <app.asar> [...]');
    process.exit(2);
  }
  const a = openAsar(asarPath);
  const entries = walkAsar(a.tree);

  if (cmd === 'list') {
    entries.sort((x, y) => y.node.size - x.node.size);
    for (const e of entries) {
      console.log(String(e.node.size).padStart(12) + '  ' + e.path + (e.node.unpacked ? '  [unpacked]' : ''));
    }
  } else if (cmd === 'cat') {
    const t = arg3.startsWith('/') ? arg3 : '/' + arg3;
    const e = entries.find((x) => x.path === t);
    if (!e) { console.error('未找到: ' + arg3); process.exit(1); }
    if (e.node.unpacked) { console.error('该条目是 unpacked，实际文件在 app.asar.unpacked/ 下'); process.exit(1); }
    process.stdout.write(readEntry(a, e.node));
  } else if (cmd === 'extract') {
    const outDir = arg3;
    const ei = rest.indexOf('--exclude');
    const exclude = ei >= 0 ? rest[ei + 1] : null;
    let n = 0, bytes = 0;
    for (const e of entries) {
      if (e.node.unpacked) continue;
      if (exclude && e.path.startsWith(exclude)) continue;
      const dest = path.join(outDir, e.path);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      const buf = readEntry(a, e.node);
      fs.writeFileSync(dest, buf);
      n++; bytes += buf.length;
    }
    console.log(`已导出 ${n} 个文件，${(bytes / 1048576).toFixed(1)} MB -> ${outDir}`);
  } else if (cmd === 'verify') {
    const limit = parseInt(arg3 || '200', 10);
    let ok = 0, bad = 0, n = 0;
    for (const e of entries) {
      if (!e.node.integrity?.hash || e.node.unpacked) continue;
      if (n++ >= limit) break;
      const buf = readEntry(a, e.node);
      const h = crypto.createHash('sha256').update(buf).digest('hex');
      if (h === e.node.integrity.hash) ok++;
      else { bad++; if (bad <= 3) console.error('  不匹配: ' + e.path); }
    }
    console.log(`抽样校验 ${n} 个：通过 ${ok}，失败 ${bad}`);
    process.exit(bad ? 1 : 0);
  } else {
    console.error('未知命令: ' + cmd);
    process.exit(2);
  }
  fs.closeSync(a.fd);
}
