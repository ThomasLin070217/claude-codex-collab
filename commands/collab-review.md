# /collab-review — Quick Cross-Model Code Review (v2)

Lightweight version of `/collab review`. Use this when you want a fast second opinion on the current diff before committing. Codex acts as a skeptical architect — it's incentivized to find problems, not to be polite.

## Protocol

1. **Get the diff and write it to a file** (v2: 走 ref，不粘贴进 prompt):
   ```bash
   mkdir -p ~/Agent/collab/work/claude
   git diff > ~/Agent/collab/work/claude/diff.txt          # unstaged (default)
   # git diff --staged > ~/Agent/collab/work/claude/diff.txt  # if user says "staged"
   wc -l ~/Agent/collab/work/claude/diff.txt
   ```

2. **Send Codex the ref, not the diff text:**
   ```bash
   ~/Agent/collab/codex-bridge.sh review architect \
     "Review the git diff at ~/Agent/collab/work/claude/diff.txt critically. Look for: bugs, edge cases, security vulnerabilities, performance issues, unclear naming, missing tests. Be specific — reference exact lines. If the diff is clean, say so briefly."
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
