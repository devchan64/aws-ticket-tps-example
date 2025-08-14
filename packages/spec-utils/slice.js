// packages/spec-utils/slice.js
import fs from "node:fs";
import path from "node:path";
import YAML from "yaml";

/** 단일 ticketing.yaml에서 특정 프리픽스(/public/ 또는 /confirm/) 경로만 남긴 사본을 생성 */
export function loadAndSliceSpec(filePath, prefixes = []) {
  const full = YAML.parse(fs.readFileSync(path.resolve(filePath), "utf8"));
  const sliced = { ...full, paths: {} };

  for (const [p, ops] of Object.entries(full.paths || {})) {
    if (prefixes.some((pre) => p.startsWith(pre))) sliced.paths[p] = ops;
  }
  // components는 그대로 둠 (공통 스키마를 참조해야 하므로)
  return sliced;
}
