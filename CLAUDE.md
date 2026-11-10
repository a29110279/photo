# 提示詞相簿（photo_prompt）

Flutter（iOS / Android）App：以自然語言提示詞篩選相片與影片並整理成相簿，全裝置端運算。
規劃見 `docs/project-evaluation.md`，實作範圍與架構見 `README.md`。

- 提交前執行 `flutter analyze` 與 `flutter test`，兩者都要通過
- 相片資料不得離開裝置；唯一允許的網路行為是下載模型
- 不要把 API Key、Token 或本機絕對路徑寫進任何會提交的檔案

## 工具分工（優先於下方工具自動產生的指示）

下方 graphify 與 GitNexus 兩段由工具自動產生，重跑工具時會被覆寫，請勿手動修改；兩段指示衝突時以本節為準。

| 情境 | 使用 |
| --- | --- |
| 架構理解、「這個功能在哪／怎麼運作」、文件與程式碼的關聯 | Graphify（`graphify query` / `path` / `explain`） |
| 修改既有的函式、類別、方法之前 | GitNexus `impact`（HIGH / CRITICAL 需先告知使用者） |
| 追蹤呼叫鏈、除錯、重新命名與重構 | GitNexus（`context`、`rename`） |
| 提交前 | 只跑 GitNexus `detect_changes`，再跑 `graphify update .` 更新圖譜 |

- **「先查圖譜」只需擇一**：兩段都要求在文字搜尋前先查自己的圖譜，依上表選一個即可，不必兩個都查。
- **文字搜尋不被禁止**：查完圖譜後，找字串常值、設定值、註解，或圖譜查無結果／回傳 `UNKNOWN` 時，直接用 grep。
- **新增檔案不需 impact 分析**；impact 只針對修改既有符號。
- **工具不可用時退回一般做法**：若 `graphify-out/graph.json` 或 `.gitnexus/` 不存在（兩者皆不進版本控制，例如雲端或 CI 環境），或指令無法執行，改用一般搜尋與閱讀原始碼，並在回覆中說明未做圖譜分析。不要為了滿足下方的 MUST / NEVER 而停止工作，也不要自行安裝工具。
- **圖譜只是導航**：結論一律以原始碼為準；圖譜與原始碼不一致時信原始碼，並重建圖譜。
- **不使用 `gitnexus wiki` 的雲端 LLM**。

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed graphify-out/graph.json is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **photo** (596 symbols, 1041 relationships, 33 execution flows).

> Index stale? Run `node .gitnexus/run.cjs analyze --index-only` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? Bootstrap with `npx`, `bunx`, or `pnpm dlx` — e.g. `bunx gitnexus@latest analyze` (npm 11 npx crash; #1939).

## Always Do

- **MUST run impact before editing.** Use `impact({target: "symbolName", direction: "upstream"})` or `node .gitnexus/run.cjs impact "symbolName" --direction upstream --repo .`; report callers, processes, and risk. Never substitute grep for graph analysis.
- **MUST analyze graph changes before committing.** Use `detect_changes({scope: "all"})` (MCP) or `node .gitnexus/run.cjs detect-changes --scope all --repo .` (CLI fallback). `partial: true` or `truncated: true` is not a clean check — a zero means unseen, not unaffected; re-run it. For regression review: `detect_changes({scope: "compare", base_ref: "claude/project-setup-implementation-p4mac3"})` or `node .gitnexus/run.cjs detect-changes --scope compare --base-ref "claude/project-setup-implementation-p4mac3" --repo .`.
- MUST warn on HIGH/CRITICAL `risk` pre-edit; never use `riskSharedAxes` to waive a HIGH/CRITICAL `risk` warning. Compare File/symbol: MCP File omits axes; Graph-RAG expands File.
- **MUST treat `risk: UNKNOWN` as unresolved, not as low.** An empty caller set is not evidence the symbol is unused — it can also mean the callers are not resolvable by the index (plain-object property access, dynamic dispatch, cross-language calls). `impact` pairs `UNKNOWN` with a `riskNote` saying so. Confirm with a text search before treating the symbol as safe to change or delete; do not proceed on the strength of a zero.
- **MUST use `query({search_query: "concept"})` for concepts/flows, `context({name: "symbolName"})` for a named symbol, or `impact` for blast radius, on read-only callers, dependencies, imports, or execution flow.** Graph first; text search only for empty/`UNKNOWN`/literals.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method before MCP/CLI impact analysis.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis, and never read `UNKNOWN` as an all-clear — it means the walk could not answer, which is the one verdict that requires confirming by other means.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit before MCP/CLI graph change analysis.

## Resources

| Resource | Use for |
| --- | --- |
| `gitnexus://repo/photo/context` | Codebase overview, check index freshness |
| `gitnexus://repo/photo/clusters` | All functional areas |
| `gitnexus://repo/photo/processes` | All execution flows |
| `gitnexus://repo/photo/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
| --- | --- |
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
