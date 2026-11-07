#!/usr/bin/env node
// AI らしい日本語の語彙を禁止する (辞書: textlint-rule-preset-ai-words-ja)。
// 公開前のリポジトリなので、追加した行だけでなく git 管理下の対象ファイル全体を見る。
//
// 使い方: node tools/ai-words/check.mjs [--github]
//   --github  GitHub Actions の ::error 形式で出す
//
// Markdown 以外 (.rb / .yml / .sh) は plain text として読む。textlint は拡張子でパーサを選ぶため、
// ファイル名に .txt を付けて渡す。そのため Markdown 以外では <!-- textlint-disable --> は使えず、
// 抑止は行単位の `ai-words-allow=<語>[,<語>]` で書く。
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { createLinter, loadTextlintrc } from "textlint";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const PATHS = ["*.md", "*.rb", "*.yml", "*.sh", "*.gemspec", "Rakefile", "exe/*"];
const EXCLUDE = [/^test\/fixtures\//, /^tools\/ai-words\/node_modules\//];
// 設定の書き間違いは「ルール 0 件で全部通る」になるので、読み込んだルールを確かめる
const EXPECTED_RULES = ["ai-words-ja/no-ai-words", "ai-words-ja/no-short-topic-comma"];
const ALLOW_MARKER = /ai-words-allow=([^\s]+)/g;
const JA = /[぀-ヿ一-鿿]/;

const github = process.argv.includes("--github");
const descriptor = await loadTextlintrc({ configFilePath: path.join(HERE, ".textlintrc.yml"), node_modulesDir: path.join(HERE, "node_modules") });
const ids = descriptor.rule.lintableDescriptors.map((d) => d.id).sort();
if (JSON.stringify(ids) !== JSON.stringify([...EXPECTED_RULES].sort())) {
  console.error(`読み込まれたルールが想定と違う: ${JSON.stringify(ids)}`);
  process.exit(2);
}
const linter = createLinter({ descriptor });

const files = execFileSync("git", ["-c", "core.quotepath=false", "ls-files", "--", ...PATHS], { cwd: ROOT })
  .toString().split("\n").filter((f) => f && !EXCLUDE.some((re) => re.test(f)));

let count = 0;
for (const file of files) {
  const text = readFileSync(path.join(ROOT, file), "utf8");
  if (!JA.test(text)) continue;
  const lines = text.split("\n");
  const name = file.endsWith(".md") ? file : `${file}.txt`;
  const { messages } = await linter.lintText(text, path.join(ROOT, name));
  for (const m of messages) {
    const line = m.loc?.start?.line ?? m.line;
    const col = (m.loc?.start?.column ?? m.column - 1) + 1;
    const allowed = new Set([...(lines[line - 1] ?? "").matchAll(ALLOW_MARKER)].flatMap((x) => x[1].split(",")));
    const word = m.message.match(/"([^"]+)"/)?.[1];
    if (word && allowed.has(word)) continue;
    count++;
    console.log(github ? `::error file=${file},line=${line},col=${col}::${m.message}` : `${file}:${line}:${col}  ${m.message}`);
  }
}
console.error(`${files.length} files, ${count} problem(s)`);
process.exit(count > 0 ? 1 : 0);
