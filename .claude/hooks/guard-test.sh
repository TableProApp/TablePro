#!/usr/bin/env bash
# Regression suite for .claude/hooks/guard.sh.
#
# Every banned pattern is assembled from parts at runtime, so the text of this file never
# contains one. That matters: the PreToolUse guards inspect the command text of whatever runs
# them, so a suite written the obvious way blocks itself.
#
# Run it after touching guard.sh: .claude/hooks/guard-test.sh
# Exit 0 when every case passes.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
G="$REPO/.claude/hooks/guard.sh"
ADD=$(printf 'a%s' dd)
COMMIT=$(printf 'com%s' mit)
PUSH=$(printf 'pu%s' sh)
pass=0
fail=0

# want: fires | silent
run() {
    local want="$1" check="$2" payload="$3" name="$4"
    local out got
    out="$(printf '%s' "$payload" | "$G" "$check" 2> /dev/null)"
    if [ -n "$out" ]; then
        got=fires
        if ! printf '%s' "$out" | jq -e . > /dev/null 2>&1; then
            printf '  BAD JSON  %-46s\n' "$name"
            fail=$((fail + 1))
            return
        fi
    else
        got=silent
    fi
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
    else
        printf '  FAIL      %-46s want=%s got=%s\n' "$name" "$want" "$got"
        fail=$((fail + 1))
    fi
}

cmd() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
wrote() { printf '{"tool_input":{"file_path":"%s","content":%s}}' "$1" "$(printf '%s' "$2" | jq -Rs .)"; }

echo "no-blanket-add"
run fires  no-blanket-add "$(cmd "git $ADD -A")"                        "-A"
run fires  no-blanket-add "$(cmd "git $ADD -u")"                        "-u"
run fires  no-blanket-add "$(cmd "git $ADD --all")"                     "--all"
run fires  no-blanket-add "$(cmd "git $ADD .")"                         "dot"
run fires  no-blanket-add "$(cmd "git -C /tmp/x $ADD -A")"              "-C then -A"
run fires  no-blanket-add "$(cmd "git stage -A")"                       "stage alias (was missed)"
run silent no-blanket-add "$(cmd "git $ADD TablePro/App.swift")"        "explicit path"
run silent no-blanket-add "$(cmd "git $ADD -p")"                        "interactive -p"
run silent no-blanket-add "$(cmd "git $ADD ./TablePro")"                "dot-slash path"
run silent no-blanket-add "$(cmd "ls -la")"                             "unrelated"

echo "no-commit-push"
run fires  no-commit-push "$(cmd "git $COMMIT -m x && git $PUSH")"      "&&"
run fires  no-commit-push "$(cmd "git $COMMIT -m x; git $PUSH")"        "semicolon"
run fires  no-commit-push "$(printf '{"tool_input":{"command":%s}}' "$(printf 'git %s -m x\ngit %s\n' "$COMMIT" "$PUSH" | jq -Rs .)")" "NEWLINE (the real gap)"
run silent no-commit-push "$(cmd "git $COMMIT -m x")"                   "commit alone"
run silent no-commit-push "$(cmd "git $PUSH -u origin b")"              "push alone"
run silent no-commit-push "$(cmd "git log --grep=$PUSH")"               "log grep"

echo "no-xcstrings-add"
run fires  no-xcstrings-add "$(cmd "git $ADD TablePro/Resources/Localizable.xcstrings")" "stage xcstrings"
run silent no-xcstrings-add "$(cmd "git diff TablePro/Resources/Localizable.xcstrings")" "diff is fine"

echo "writing-style"
run fires  writing-style "$(wrote "$REPO/docs/x.md" "this is a seamless flow")"          "banned word"
run fires  writing-style "$(wrote "$REPO/docs/x.md" "an em dash here — like this")"      "em dash"
run silent writing-style "$(wrote "$REPO/x.swift" "let robustness = 1")"                 "robustness (was false positive)"
run silent writing-style "$(wrote "$REPO/x.swift" "comprehensiveCheck()")"               "comprehensiveCheck (was false positive)"
run silent writing-style "$(wrote "$REPO/docs/x.md" "a short specific sentence")"        "clean prose"
run silent writing-style "$(wrote "$REPO/.claude/hooks/guard.sh" "seamless robust —")"   "guard.sh itself (self-reference)"
run silent writing-style "$(wrote "/tmp/outside.md" "totally seamless")"                 "outside repo"

echo "regenerate-note"
run fires  regenerate-note "$(printf '{"tool_input":{"file_path":"%s"}}' "$REPO/TablePro/BrandNewFile.swift")"          "untracked .swift"
run silent regenerate-note "$(printf '{"tool_input":{"file_path":"%s"}}' "$REPO/TablePro/AppDelegate.swift")"           "tracked .swift (was noisy)"
run silent regenerate-note "$(printf '{"tool_input":{"file_path":"%s"}}' "$REPO/README.md")"                            "not swift"

echo "malformed input fails open"
run silent no-blanket-add  '{}'          "empty object"
run silent writing-style   'not json'    "garbage stdin"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
