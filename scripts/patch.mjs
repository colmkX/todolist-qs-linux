#!/usr/bin/env node
/**
 * 通用 asar 补丁引擎
 * ------------------------------------------------------------------
 * 设计目标：新版本发布后，即使 webpack 输出的文件名哈希变了、代码被压缩得
 * 更狠，也能自动找到目标并打补丁；做不到时明确报错而不是默默跳过。
 *
 * 工作方式：
 *   1. 解析 asar（pickle 头 + JSON 目录 + 拼接的文件数据）
 *   2. 按补丁声明的正则在各文件中搜索
 *   3. 替换后若所有文件长度不变 -> 原地字节替换（快、稳、不动结构）
 *      若有文件长度变化     -> 自动重打包（重建头部与所有偏移）
 *   4. 同步更新头部记录的 SHA-256
 *
 * 用法：
 *   node patch.mjs <app.asar>              # 应用全部补丁
 *   node patch.mjs <app.asar> --list       # 只列出补丁定义
 *   node patch.mjs <app.asar> --dry-run    # 只报告会改什么，不写盘
 *   node patch.mjs <app.asar> --only <id>  # 只应用指定补丁
 */

import fs from 'node:fs';
import crypto from 'node:crypto';

const align4 = (n) => (n + 3) & ~3;

// ==================================================================
// 补丁声明表
// 新增修复时在这里加一条即可，其余流程无需改动。
// ==================================================================
const PATCHES = [
  {
    id: 'titlebar-on-linux',
    desc:
      'Linux 上启用应用自绘标题栏。原版主进程给非 macOS 都设了 frame:false，' +
      '而渲染进程只给 win32 开自绘标题栏，两相叠加导致 Linux 窗口没有任何' +
      '关闭/最小化/最大化按钮。',
    // 只在这些文件里找（正则匹配 asar 内路径）
    files: /^\/js\/[^/]*\.js$/,
    // 同时兼容压缩与未压缩两种写法
    pattern: /hasTitleBar\s*:\s*"win32"\s*===\s*process\.platform/g,
    // 返回替换文本；与原串等长时走原地替换
    replace: () => 'hasTitleBar:process.platform!="darwin"',
    // 若未来写法变化，等长方案失效，则允许重打包兜底
    allowRepack: true,
  },
];

// ==================================================================
// asar 读写
// ==================================================================
function readAsar(asarPath) {
  // 必须 'r+'：等长补丁走原地替换，需要写权限
  const fd = fs.openSync(asarPath, 'r+');
  const h = Buffer.alloc(16);
  fs.readSync(fd, h, 0, 16, 0);
  const headerSize = h.readUInt32LE(4);
  const jsonLen = h.readUInt32LE(12);
  const jb = Buffer.alloc(jsonLen);
  fs.readSync(fd, jb, 0, jsonLen, 16);
  const tree = JSON.parse(jb.toString('utf8'));
  const dataStart = 8 + headerSize;
  return { fd, tree, dataStart, jsonLen };
}

function walk(node, prefix, out) {
  for (const [name, child] of Object.entries(node.files || {})) {
    const p = `${prefix}/${name}`;
    if (child.files) walk(child, p, out);
    else out.push({ path: p, node: child });
  }
}

function readEntry(fd, dataStart, entry) {
  const buf = Buffer.alloc(entry.size);
  fs.readSync(fd, buf, 0, entry.size, dataStart + parseInt(entry.offset, 10));
  return buf;
}

/** 重新计算并写入 integrity（并保持 blocks 与整体一致） */
function refreshIntegrity(entry, buf) {
  if (!entry.integrity) return;
  const blockSize = entry.integrity.blockSize || 4 * 1024 * 1024;
  const blocks = [];
  for (let off = 0; off < buf.length; off += blockSize) {
    blocks.push(crypto.createHash('sha256').update(buf.subarray(off, off + blockSize)).digest('hex'));
  }
  entry.integrity.hash = crypto.createHash('sha256').update(buf).digest('hex');
  entry.integrity.blocks = blocks;
}

/**
 * 重打包：把（可能已变长的）文件数据重建成一个新的 asar。
 * 只处理非 unpacked 条目；unpacked 条目保持外部引用不变。
 */
function repack(outPath, entries, payloads) {
  const json = Buffer.from(JSON.stringify(entries.tree), 'utf8');
  const jsonLen = json.length;
  const innerPayload = align4(4 + jsonLen);
  const headerSize = 4 + innerPayload;
  const dataStart = 8 + headerSize;

  // 重新计算偏移
  let cursor = 0;
  const order = [];
  walk(entries.tree, '', order);
  for (const { path: p, node } of order) {
    if (node.unpacked) continue;
    const buf = payloads.get(p);
    if (!buf) continue;
    node.size = buf.length;
    node.offset = String(cursor);
    refreshIntegrity(node, buf);
    cursor += buf.length;
  }

  const json2 = Buffer.from(JSON.stringify(entries.tree), 'utf8');
  if (json2.length !== jsonLen) {
    throw new Error('重打包内部错误：目录 JSON 长度在重算偏移后发生变化');
  }

  const head = Buffer.alloc(dataStart);
  head.writeUInt32LE(4, 0);
  head.writeUInt32LE(headerSize, 4);
  head.writeUInt32LE(innerPayload, 8);
  head.writeUInt32LE(jsonLen, 12);
  json.copy(head, 16);

  const fd = fs.openSync(outPath, 'w');
  fs.writeSync(fd, head);
  for (const { path: p, node } of order) {
    if (node.unpacked) continue;
    const buf = payloads.get(p);
    if (buf) fs.writeSync(fd, buf);
  }
  fs.closeSync(fd);
}

// ==================================================================
// 主流程
// ==================================================================
const argv = process.argv.slice(2);
const asarPath = argv.find((a) => !a.startsWith('--'));
const dryRun = argv.includes('--dry-run');
const onlyIdx = argv.indexOf('--only');
const only = onlyIdx >= 0 ? argv[onlyIdx + 1] : null;

if (!asarPath || argv.includes('--list')) {
  console.log('可用补丁：');
  for (const p of PATCHES) console.log(`  ${p.id}\n    ${p.desc}`);
  if (!asarPath) process.exit(asarPath ? 0 : 2);
}

const asar = readAsar(asarPath);
const allEntries = [];
walk(asar.tree, '', allEntries);
console.log(`asar: ${asarPath}`);
console.log(`条目总数: ${allEntries.length}，数据区起点: ${asar.dataStart}`);

const applied = [];
const payloads = new Map();
let needsRepack = false;

for (const patch of PATCHES) {
  if (only && patch.id !== only) continue;

  const candidates = allEntries.filter((e) => !e.node.unpacked && patch.files.test(e.path));
  let hit = null;
  let newBuf = null;
  let matches = 0;

  for (const e of candidates) {
    const buf = readEntry(asar.fd, asar.dataStart, e.node);
    const found = [...buf.toString('binary').matchAll(patch.pattern)];
    if (!found.length) continue;

    const text = buf.toString('utf8');
    let out = '';
    let last = 0;
    patch.pattern.lastIndex = 0;
    let mm;
    let n = 0;
    while ((mm = patch.pattern.exec(text)) !== null) {
      out += text.slice(last, mm.index) + patch.replace(mm[0]);
      last = mm.index + mm[0].length;
      n++;
    }
    out += text.slice(last);

    const nb = Buffer.from(out, 'utf8');
    if (nb.length !== buf.length) needsRepack = true;
    hit = e; newBuf = nb; matches = n;
    break; // 每个补丁只作用于第一个命中的文件
  }

  if (!hit) {
    console.error(`✗ [${patch.id}] 未找到目标，跳过。新版本可能改了这段代码，需要人工确认。`);
    applied.push({ id: patch.id, status: 'not-found' });
    continue;
  }

  console.log(
    `✓ [${patch.id}] ${hit.path} 命中 ${matches} 处` +
      (newBuf.length === hit.node.size
        ? '，长度不变 → 可原地替换'
        : `，长度 ${hit.node.size} → ${newBuf.length} → 需重打包`)
  );
  applied.push({ id: patch.id, status: 'ok', file: hit.path, matches });
  payloads.set(hit.path, newBuf);
}

if (dryRun) {
  console.log('\n--dry-run：未写入任何内容。');
  fs.closeSync(asar.fd);
  process.exit(0);
}

if (!applied.some((a) => a.status === 'ok')) {
  console.error('\n没有应用任何补丁。');
  fs.closeSync(asar.fd);
  process.exit(1);
}

if (needsRepack) {
  // 读出全部文件（除 unpacked 与被改动的）
  console.log('\n执行重打包…');
  const tmp = `${asarPath}.repack.tmp`;
  for (const e of allEntries) {
    if (e.node.unpacked || payloads.has(e.path)) continue;
    payloads.set(e.path, readEntry(asar.fd, asar.dataStart, e.node));
  }
  fs.closeSync(asar.fd);
  repack(tmp, asar, payloads);
  fs.renameSync(tmp, asarPath);
  console.log('重打包完成 ✓');
} else {
  // 原地替换 + 更新头部哈希
  for (const [p, buf] of payloads) {
    const e = allEntries.find((x) => x.path === p);
    fs.writeSync(asar.fd, buf, 0, buf.length, asar.dataStart + parseInt(e.node.offset, 10));
    const oldHash = e.node.integrity?.hash;
    const newHash = crypto.createHash('sha256').update(buf).digest('hex');
    if (oldHash) {
      const h = Buffer.alloc(asar.jsonLen);
      fs.readSync(asar.fd, h, 0, asar.jsonLen, 16);
      let at = 0, n = 0;
      while ((at = h.indexOf(Buffer.from(oldHash), at)) >= 0) {
        Buffer.from(newHash).copy(h, at);
        at += 64; n++;
      }
      fs.writeSync(asar.fd, h, 0, asar.jsonLen, 16);
      console.log(`  更新头部哈希 ${n} 处：${p}`);
    }
  }
  fs.closeSync(asar.fd);
  console.log('原地替换完成 ✓');
}

const bad = applied.filter((a) => a.status !== 'ok');
if (bad.length) {
  console.error(`\n注意：${bad.length} 个补丁未应用（见上）。`);
  process.exit(1);
}
console.log('\n全部补丁应用成功 ✓');
