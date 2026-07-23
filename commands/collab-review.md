# /collab-review — Quick Cross-Model Code Review

Lightweight version of `/collab review`. Use this when you want a fast second opinion on the current diff before committing. Codex acts as a skeptical architect — it's incentivized to find problems, not to be polite.

## Protocol

1. **Get the diff.** Run `git diff` (unstaged changes) or `git diff --staged` (staged changes). If the user says `/collab-review staged`, use staged. Default: unstaged.

2. **Send to Codex as architect:**
   ```bash
   ~/Agent/collab/codex-bridge.sh review architect \
     "Review this git diff critically. Look for: bugs, edge cases, security vulnerabilities, performance issues, unclear naming, missing tests. Be specific — reference exact lines. If the diff is clean, say so briefly. Here is the diff:

   [paste diff]"
   ```

3. **Filter and present findings as a table:**

   | Severity | Issue | File:Line | Recommendation |
   |---|---|---|---|
   | 🔴 Critical | ... | ... | ... |
   | 🟡 Warning | ... | ... | ... |
   | 🔵 Nitpick | ... | ... | ... |

4. **If no issues found**, say: "Codex found no issues with this diff." Don't pad — an honest clean review is valuable signal.

## Safety

- **Never commit automatically.** The user reviews the findings and decides.
- If Codex suggests changes, the user can ask Claude to apply them. Claude should re-review before applying.
- If the diff is very large (>500 lines), warn the user: "This is a large diff. Codex review may miss things. Consider splitting into smaller commits."
