import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, mkdir, readFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { generateWhatsNew, assembleWhatsNew, PLAY_WHATS_NEW_LIMIT } from './generate_whatsnew.mjs';

const SAMPLE_V213 = `**나만의 안전신문고 Android 앱 v2.1.3 · 빌드 41**

### 버그 수정
- 단독 모드에서 신고 내역 다시 불러오기가 잠시 서버에 연결되지 않거나 다른 전송 작업과 겹치면 멈춘 채 다시 진행되지 않던 문제를 고쳤습니다. 이제 잠시 뒤 자동으로 다시 시도하고, 대기 상황을 카드와 알림으로 알려 줍니다.
- 업데이트 전에 진행하던 작업이 남아 있으면 해당 작업의 대기 시간이 끝난 뒤 다시 불러오기를 이어갑니다. 자동 재시도를 모두 마쳐도 진행할 수 없으면 직접 다시 시도할 수 있도록 안내합니다.
- 다시 불러오기가 필요한지 확인하지 못했을 때 복구 버튼이 사라지던 문제를 고쳤습니다. 이제 같은 화면에서 '다시 시도'를 눌러 준비를 다시 진행할 수 있습니다.

**Full Changelog**: https://github.com/Fentanest/safetyreport-mobile/compare/v2.1.2...v2.1.3
`;

test('제목과 Full Changelog 줄을 제거하고 목록을 "• "로 바꾼다', () => {
  const out = generateWhatsNew(SAMPLE_V213);
  assert.ok(!out.includes('나만의 안전신문고 Android 앱'), '제목이 남아있으면 안 됨');
  assert.ok(!out.includes('Full Changelog'), 'Full Changelog 줄이 남아있으면 안 됨');
  assert.ok(!out.includes('**'), '마크다운 강조 기호가 남아있으면 안 됨');
  assert.ok(!/^#+/m.test(out), '# 기호가 남아있으면 안 됨');
  assert.ok(!/^-\s/m.test(out), '원본 "- " 목록 기호가 남아있으면 안 됨');
  assert.ok(out.includes('버그 수정'), '섹션 제목 글자는 남아야 함');
  assert.ok(out.startsWith('버그 수정'), '제목이 지워졌으므로 첫 줄은 섹션 제목이어야 함');
  const bulletLines = out.split('\n').filter(l => l.startsWith('• '));
  assert.equal(bulletLines.length, 3, '목록 3개가 모두 "• " 로 바뀌어야 함');
  assert.ok(bulletLines[0].includes('단독 모드에서 신고 내역'));
  assert.ok(out.length <= PLAY_WHATS_NEW_LIMIT);
});

test('여러 섹션(헤더)이 있으면 헤더 텍스트도 기호 없이 남는다', () => {
  const md = `**제목**

### 새 기능
- 새 기능 설명입니다.

### 버그 수정
- 버그 수정 설명입니다.

**Full Changelog**: https://example.com
`;
  const out = generateWhatsNew(md);
  assert.deepEqual(out.split('\n'), ['새 기능', '• 새 기능 설명입니다.', '버그 수정', '• 버그 수정 설명입니다.']);
});

test('500자 제한을 넘으면 문장 단위로 자르고 말줄임표 없이 완결된 문장으로 끝난다', () => {
  const longSentence = (n) => `이것은 아주 긴 테스트 문장입니다 번호 ${n} 입니다. `.repeat(1).trim();
  const bullets = Array.from({ length: 30 }, (_, i) => `- ${longSentence(i)} ${longSentence(i)} ${longSentence(i)}`).join('\n');
  const md = `**제목**\n\n### 버그 수정\n${bullets}\n\n**Full Changelog**: https://example.com\n`;
  const out = generateWhatsNew(md);
  assert.ok(out.length <= PLAY_WHATS_NEW_LIMIT, `결과가 ${PLAY_WHATS_NEW_LIMIT}자를 넘음: ${out.length}`);
  assert.ok(!out.includes('…'), '말줄임표가 없어야 함');
  assert.ok(!out.endsWith('...'), '...으로 끝나면 안 됨');
  assert.ok(/[.!?]$/.test(out), '완결된 문장(마침표 등)으로 끝나야 함');
});

test('짧은 노트는 그대로 전부 포함되고 500자를 넘지 않는다', () => {
  const out = generateWhatsNew(SAMPLE_V213);
  const expectedFull =
    '버그 수정\n' +
    '• 단독 모드에서 신고 내역 다시 불러오기가 잠시 서버에 연결되지 않거나 다른 전송 작업과 겹치면 멈춘 채 다시 진행되지 않던 문제를 고쳤습니다. 이제 잠시 뒤 자동으로 다시 시도하고, 대기 상황을 카드와 알림으로 알려 줍니다.\n' +
    '• 업데이트 전에 진행하던 작업이 남아 있으면 해당 작업의 대기 시간이 끝난 뒤 다시 불러오기를 이어갑니다. 자동 재시도를 모두 마쳐도 진행할 수 없으면 직접 다시 시도할 수 있도록 안내합니다.\n' +
    "• 다시 불러오기가 필요한지 확인하지 못했을 때 복구 버튼이 사라지던 문제를 고쳤습니다. 이제 같은 화면에서 '다시 시도'를 눌러 준비를 다시 진행할 수 있습니다.";
  assert.equal(out, expectedFull);
  assert.ok(out.length < PLAY_WHATS_NEW_LIMIT);
});

test('assembleWhatsNew: 헤더 하나가 제한을 넘기면 그 헤더부터 모두 버린다(말줄임표 없이)', () => {
  const entries = [
    { isHeader: false, sentences: ['짧은 문장.'] },
    { isHeader: true, sentences: ['매우'.repeat(600)] },
    { isHeader: false, sentences: ['이후 문장은 포함되지 않는다.'] },
  ];
  const out = assembleWhatsNew(entries, 500);
  assert.equal(out, '• 짧은 문장.');
});

test('CLI: docs/releases/v<VERSION>.md 가 없으면 실패하고 파일을 만들지 않는다', () => {
  const run = async () => {
    const dir = await mkdtemp(join(tmpdir(), 'sr-whatsnew-'));
    try {
      await writeFile(join(dir, 'VERSION'), '9.9.9+9\n');
      await mkdir(join(dir, 'docs', 'releases'), { recursive: true });
      let threw = false;
      try {
        execFileSync(process.execPath, [resolve('scripts/generate_whatsnew.mjs')], { cwd: dir, stdio: 'pipe' });
      } catch (err) {
        threw = true;
        assert.ok(err.status !== 0);
        assert.match(err.stderr.toString(), /출시 노트가 없습니다/);
      }
      assert.ok(threw, 'VERSION 에 해당하는 릴리즈 노트가 없으면 실패해야 함');
      await assert.rejects(readFile(join(dir, 'whatsnew', 'whatsnew-ko-KR')));
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  };
  return run();
});

test('CLI: WHATSNEW_ALLOW_MISSING=1 이면 노트가 없어도 기본 문구로 대체하고 실패하지 않는다', () => {
  const run = async () => {
    const dir = await mkdtemp(join(tmpdir(), 'sr-whatsnew-'));
    try {
      await writeFile(join(dir, 'VERSION'), '9.9.9+9\n');
      await mkdir(join(dir, 'docs', 'releases'), { recursive: true });
      execFileSync(process.execPath, [resolve('scripts/generate_whatsnew.mjs')], {
        cwd: dir,
        stdio: 'pipe',
        env: { ...process.env, WHATSNEW_ALLOW_MISSING: '1', ANDROID_VERSION_CODE: '171' },
      });
      const content = await readFile(join(dir, 'whatsnew', 'whatsnew-ko-KR'), 'utf8');
      assert.equal(content, '테스트 빌드 9.9.9 (171)');
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  };
  return run();
});

test('CLI: WHATSNEW_ALLOW_MISSING=1 이어도 노트 파일이 있으면 노트 기반으로 만든다', () => {
  const run = async () => {
    const dir = await mkdtemp(join(tmpdir(), 'sr-whatsnew-'));
    try {
      await writeFile(join(dir, 'VERSION'), '3.4.5+9\n');
      await mkdir(join(dir, 'docs', 'releases'), { recursive: true });
      await writeFile(join(dir, 'docs', 'releases', 'v3.4.5.md'), SAMPLE_V213.replace(/2\.1\.3/g, '3.4.5'));
      execFileSync(process.execPath, [resolve('scripts/generate_whatsnew.mjs')], {
        cwd: dir,
        stdio: 'pipe',
        env: { ...process.env, WHATSNEW_ALLOW_MISSING: '1', ANDROID_VERSION_CODE: '171' },
      });
      const content = await readFile(join(dir, 'whatsnew', 'whatsnew-ko-KR'), 'utf8');
      assert.ok(content.includes('버그 수정'));
      assert.ok(!content.includes('테스트 빌드'));
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  };
  return run();
});

test('CLI: docs/releases/v<VERSION>.md 가 있으면 whatsnew/whatsnew-ko-KR 을 만든다', () => {
  const run = async () => {
    const dir = await mkdtemp(join(tmpdir(), 'sr-whatsnew-'));
    try {
      await writeFile(join(dir, 'VERSION'), '3.4.5+9\n');
      await mkdir(join(dir, 'docs', 'releases'), { recursive: true });
      await writeFile(join(dir, 'docs', 'releases', 'v3.4.5.md'), SAMPLE_V213.replace(/2\.1\.3/g, '3.4.5'));
      execFileSync(process.execPath, [resolve('scripts/generate_whatsnew.mjs')], { cwd: dir, stdio: 'pipe' });
      const content = await readFile(join(dir, 'whatsnew', 'whatsnew-ko-KR'), 'utf8');
      assert.ok(content.includes('버그 수정'));
      assert.ok(content.length <= PLAY_WHATS_NEW_LIMIT);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  };
  return run();
});

// 2026-10-13: Play alpha 수동 업로드 — 입력 문구 → docs/releases/unreleased.md → 기본 문구(커밋 포함) 순.
async function runCli(env, files = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'sr-whatsnew-'));
  try {
    await writeFile(join(dir, 'VERSION'), '2.2.0+42\n');
    await mkdir(join(dir, 'docs', 'releases'), { recursive: true });
    for (const [name, body] of Object.entries(files)) await writeFile(join(dir, 'docs', 'releases', name), body);
    execFileSync(process.execPath, [resolve('scripts/generate_whatsnew.mjs')], {
      cwd: dir, stdio: 'pipe',
      env: { ...process.env, WHATSNEW_ALLOW_MISSING: '1', WHATSNEW_UNRELEASED: '1', ANDROID_VERSION_CODE: '173', WHATSNEW_COMMIT: 'abc1234', ...env },
    });
    return await readFile(join(dir, 'whatsnew', 'whatsnew-ko-KR'), 'utf8');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('CLI(unreleased): unreleased.md 내용으로 만들고 첫 소제목을 버리지 않는다, v<이름>.md 는 쓰지 않는다', async () => {
  const content = await runCli({}, {
    'unreleased.md': '<!-- 미출시 -->\n### 개선\n- 검색이 빨라졌습니다.\n',
    'v2.2.0.md': SAMPLE_V213.replace(/2\.1\.3/g, '2.2.0'),
  });
  assert.equal(content, '개선\n• 검색이 빨라졌습니다.');
});

test('CLI(unreleased): 비었거나(주석만) 없으면 기본 문구에 커밋을 붙인다', async () => {
  assert.equal(await runCli({}, { 'unreleased.md': '<!-- 미출시 -->\n' }), '테스트 빌드 2.2.0 (173) · abc1234');
  assert.equal(await runCli({}), '테스트 빌드 2.2.0 (173) · abc1234');
});

test('CLI(unreleased): 입력 문구가 있으면 그것이 우선이고 500자를 넘으면 실패한다', async () => {
  assert.equal(await runCli({ WHATSNEW_TEXT: '직접 입력' }, { 'unreleased.md': '### 개선\n- x\n' }), '직접 입력');
  await assert.rejects(runCli({ WHATSNEW_TEXT: '가'.repeat(501) }));
});
