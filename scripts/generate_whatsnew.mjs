// docs/releases/v<VERSION>.md(사람이 쓰는 릴리즈 노트, 예: docs/releases/v2.1.3.md)에서
// Google Play 내부 테스트 업로드용 "출시 노트"(whatsnew-ko-KR)를 만든다.
//
// 변환 규칙:
// - 제목 줄(파일 맨 위 **나만의 안전신문고 Android 앱 v... · 빌드 ...**)과
//   **Full Changelog**: ... 줄은 제거한다(사용자에게 보여줄 내용이 아님).
// - 마크다운 기호(#, *, `)는 제거하고 글자만 남긴다.
// - 목록(- ...)은 "• "로 바꾼다.
// - Google Play "whats new" 글자 수 제한(500자)을 넘으면 문장 단위로 잘라서
//   500자 이내로 맞추고, "…" 같은 말줄임표를 붙이지 않는다(마지막 문장은 항상 완결된 문장).
//
// 이 파일은 CLI로도, 라이브러리로도 쓴다(단위 시험은 scripts/generate_whatsnew.test.mjs).

export const PLAY_WHATS_NEW_LIMIT = 500;

/** "**bold**", "`code`" 등 마크다운 강조 기호만 제거하고 글자는 남긴다. */
function stripInlineMarkdown(text) {
  return text.replace(/\*\*/g, '').replace(/`/g, '').trim();
}

/**
 * 릴리즈 노트 마크다운을 "항목" 배열로 분해한다.
 * 각 항목은 { isHeader: boolean, sentences: string[] } 형태다.
 * - 제목 줄(파일의 첫 비어있지 않은 줄)과 **Full Changelog** 줄은 버린다.
 * - "### 제목" 줄은 헤더 항목(문장 1개, 쪼개지 않음)으로 만든다.
 * - "- 내용" 줄은 목록 항목으로 만들고, 내용을 문장 단위로 쪼갠다.
 */
function parseReleaseNotes(markdown) {
  const lines = markdown.replace(/\r\n/g, '\n').split('\n');
  const entries = [];
  let titleSkipped = false;

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (line === '') continue;

    if (!titleSkipped) {
      // 파일의 첫 비어있지 않은 줄은 항상 "**... v<버전> · 빌드 ...**" 제목이다.
      titleSkipped = true;
      continue;
    }

    if (/^\*\*Full Changelog\*\*/i.test(line)) {
      // Full Changelog 링크 줄 이후에는 사용자에게 보여줄 내용이 없다.
      break;
    }

    if (/^#+\s*/.test(line)) {
      const headerText = stripInlineMarkdown(line.replace(/^#+\s*/, ''));
      if (headerText) entries.push({ isHeader: true, sentences: [headerText] });
      continue;
    }

    if (/^-\s*/.test(line)) {
      const bulletText = stripInlineMarkdown(line.replace(/^-\s*/, ''));
      if (!bulletText) continue;
      const sentences = splitSentences(bulletText);
      entries.push({ isHeader: false, sentences });
      continue;
    }

    // 예상 밖 줄(리스트도 헤더도 아님)은 그대로 한 문장짜리 목록 항목으로 다룬다.
    const text = stripInlineMarkdown(line);
    if (text) entries.push({ isHeader: false, sentences: splitSentences(text) });
  }

  return entries;
}

/** 마침표/물음표/느낌표 뒤에서 문장을 쪼갠다. 끝맺음 기호가 없으면 전체를 한 문장으로 본다. */
function splitSentences(text) {
  const matches = text.match(/[^.!?]+[.!?]+(?:\s+|$)/g);
  if (!matches) return [text.trim()];
  return matches.map(s => s.trim()).filter(Boolean);
}

/**
 * entries를 Google Play 글자 수 제한(기본 500자) 안에서 문장 단위로 조립한다.
 * 제한을 넘기면 그 자리에서 멈추고(이후 항목은 버림), "…" 등 말줄임표를 붙이지 않는다.
 */
export function assembleWhatsNew(entries, limit = PLAY_WHATS_NEW_LIMIT) {
  const resultLines = [];

  const fits = candidateLines => candidateLines.join('\n').length <= limit;

  outer:
  for (const entry of entries) {
    if (entry.isHeader) {
      const candidate = [...resultLines, entry.sentences[0]];
      if (!fits(candidate)) break outer;
      resultLines.push(entry.sentences[0]);
      continue;
    }

    let buffer = '';
    for (const sentence of entry.sentences) {
      const candidateBuffer = buffer ? `${buffer} ${sentence}` : sentence;
      const candidateLines = [...resultLines, `• ${candidateBuffer}`];
      if (!fits(candidateLines)) {
        if (buffer) resultLines.push(`• ${buffer}`);
        break outer;
      }
      buffer = candidateBuffer;
    }
    resultLines.push(`• ${buffer}`);
  }

  return resultLines.join('\n').trimEnd();
}

/** docs/releases/v<VERSION>.md 전체 마크다운 텍스트를 받아 whatsnew-ko-KR 본문을 돌려준다. */
export function generateWhatsNew(markdown, limit = PLAY_WHATS_NEW_LIMIT) {
  const entries = parseReleaseNotes(markdown);
  return assembleWhatsNew(entries, limit);
}

async function main() {
  const { readFile, writeFile, mkdir } = await import('node:fs/promises');
  const { resolve } = await import('node:path');

  const rawVersion = (await readFile(resolve('VERSION'), 'utf8')).trim();
  const buildName = rawVersion.split('+')[0];
  const releaseNotePath = resolve('docs', 'releases', `v${buildName}.md`);

  let markdown;
  try {
    markdown = await readFile(releaseNotePath, 'utf8');
  } catch {
    console.error(`::error::출시 노트가 없습니다: docs/releases/v${buildName}.md (버전 노트 없이 Play 에 올리지 않습니다)`);
    process.exit(1);
  }

  const whatsNew = generateWhatsNew(markdown);
  if (!whatsNew) {
    console.error(`::error::docs/releases/v${buildName}.md 에서 추출한 출시 노트가 비어 있습니다.`);
    process.exit(1);
  }

  const outDir = resolve('whatsnew');
  await mkdir(outDir, { recursive: true });
  const outPath = resolve(outDir, 'whatsnew-ko-KR');
  await writeFile(outPath, whatsNew, 'utf8');
  console.log(`✅ ${outPath} (${whatsNew.length}자)`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
