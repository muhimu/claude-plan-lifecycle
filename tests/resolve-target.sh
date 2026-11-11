#!/usr/bin/env bash
# resolve-target splits the target off the arguments, falls back to the
# current branch's PR or the session's PRs, finds the stack (native, "## Stack"
# table, base-branch chain) and picks the checkout to work in.
# gh is a fake on PATH that answers from fixture files; git runs for real in
# temp repos.
# shellcheck disable=SC2016  # backticks inside jq filters are text
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
fail=0
# check DESC CMD... — run CMD; on failure print FAIL: DESC.
check() { local d="$1"; shift; if ! "$@"; then echo "FAIL: $d"; echo "  output: $(cat "$tmp/out")"; fail=1; fi; }
# has JQ_FILTER — the last output satisfies the jq filter.
# shellcheck disable=SC2329  # runs through check
has() { jq -e "$1" "$tmp/out" > /dev/null 2>&1; }

command -v jq > /dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# The fake gh: its arguments, joined with "_" and stripped to [A-Za-z0-9_.-],
# name a fixture: <name> is stdout, <name>.err is stderr with exit 1. A
# fixture under $GH_FIX/<basename of cwd>/ wins over one under $GH_FIX/.
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
key="$(printf '%s_' "$@" | tr '/#,' '___' | tr -cd 'A-Za-z0-9_.-')"
key="${key%_}"
for d in "$GH_FIX/$(basename "$PWD")" "$GH_FIX"; do
  if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; exit 1; fi
  if [ -f "$d/$key" ]; then cat "$d/$key"; exit 0; fi
done
echo "fake gh: no fixture $key" >&2
exit 97
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export GH_FIX="$tmp/fix"
mkdir "$GH_FIX"
# fix NAME CONTENT / fixerr NAME STDERR — a fixture (NAME may have a dir).
fix() { mkdir -p "$(dirname "$GH_FIX/$1")"; printf '%s\n' "$2" > "$GH_FIX/$1"; }
fixerr() { mkdir -p "$(dirname "$GH_FIX/$1")"; printf '%s\n' "$2" > "$GH_FIX/$1.err"; }
# run DIR ARGS... — resolve-target in DIR; output in $tmp/out, status in rc.
run() { local d="$1"; shift; (cd "$d" && "$root/bin/resolve-target" "$@") > "$tmp/out" 2>&1; rc=$?; }

# A repo "acme/app" with a three-slice stack: main checkout on main, and a
# worktree on s2. s1, s2, s3 are branches; s3 is the top.
g() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }
main="$tmp/app"
g init -q "$main"
g -C "$main" commit -q --allow-empty -m base
for b in s1 s2 s3; do g -C "$main" checkout -q -b "$b"; g -C "$main" commit -q --allow-empty -m "$b"; done
sha1="$(git -C "$main" rev-parse s1)" sha2="$(git -C "$main" rev-parse s2)" sha3="$(git -C "$main" rev-parse s3)"
g -C "$main" checkout -q main
wt="$tmp/wt-s2"
g -C "$main" worktree add -q "$wt" s2
other="$tmp/elsewhere"   # a checkout of another repo
g init -q "$other"

pr() { printf '{"number":%s,"state":"%s","merged_at":%s,"title":"t%s","head":{"ref":"%s","sha":"%s"},"base":{"ref":"%s"}}' "$@"; }
stack7="{\"pull_requests\":[$(pr 11 closed '"2026-01-01T00:00:00Z"' 11 s1 "$sha1" main),$(pr 12 open null 12 s2 "$sha2" s1),$(pr 13 open null 13 s3 "$sha3" s2)]}"
fix repo_view_--json_nameWithOwner '{"nameWithOwner":"acme/app"}'
fix repo_view_acme_app_--json_nameWithOwner '{"nameWithOwner":"acme/app"}'
fix elsewhere/repo_view_--json_nameWithOwner '{"nameWithOwner":"acme/other"}'
fix api_repos_acme_app_stacks_7 "$stack7"
for n in 11 12 13 20 30 31 32 40; do fixerr "api_repos_acme_app_stacks_$n" 'gh: Not Found (HTTP 404)'; done
fix api_repos_acme_app_pulls_12 '{"number":12,"stack":{"number":7,"position":2,"size":3}}'
fix api_repos_acme_app_pulls_13 '{"number":13,"stack":{"number":7,"position":3,"size":3}}'

# --- stack mode: a native stack, by stack number and by one of its PRs
run "$main" stack 7
check "stack number: ok" [ "$rc" -eq 0 ]
check "stack number: no anchor PR, three slices bottom first" has '.status == "ok" and .anchor_pr == null and .stack_num == 7 and .stacked and .size == 3 and ([.slices[].number] == [11,12,13])'
check "a merged PR the API calls closed reads merged" has '.slices[0].state == "merged" and .slices[1].state == "open"'
check "slices carry head, base and sha" has ".slices[1] | .head == \"s2\" and .base == \"s1\" and .sha == \"$sha2\""
check "label of a native stack" has '.label == "stack #7" and .repo == "acme/app"'

run "$main" stack 12
check "PR of a native stack: position 2/3" has '.anchor_pr == 12 and .stack_num == 7 and .position == 2 and .size == 3'
run "$other" stack acme/app#12
check "OWNER/REPO#N works from another repo's checkout" has '.repo == "acme/app" and .anchor_pr == 12 and .stack_num == 7'
run "$other" stack https://github.com/acme/app/pull/13/files
check "a PR URL is a PR, never tried as a stack" has '.anchor_pr == 13 and .position == 3'

fixerr api_repos_acme_app_stacks_99 'gh: Bad credentials (HTTP 401)'
run "$main" stack 99
check "an error other than 404 stops, it is not read as a PR" has '.status == "stop" and (.message | contains("401"))'
check "a stop exits 1" [ "$rc" -eq 1 ]

# --- an unstacked PR
slice() { printf '{"number":%s,"state":"%s","mergedAt":%s,"title":"t%s","headRefName":"%s","baseRefName":"%s","headRefOid":"%s"}' "$@"; }
V=--json_number_state_mergedAt_title_headRefName_baseRefName_headRefOid
fix api_repos_acme_app_pulls_20 '{"number":20,"stack":null}'
fix pr_view_20_-R_acme_app_--json_body '{"body":"## Summary\nnothing"}'
fix repo_view_acme_app_--json_defaultBranchRef '{"defaultBranchRef":{"name":"main"}}'
fix "pr_view_20_-R_acme_app_$V" "$(slice 20 OPEN null 20 solo main abc)"
fix pr_list_-R_acme_app_--base_solo_--state_open_--json_number_headRefName '[]'
run "$main" stack 20
check "unstacked PR: one slice, not stacked, no label" has '.stacked == false and .size == 1 and .position == 1 and .stack_num == null and .label == null and .slices[0].state == "open"'

# --- fallback: the "## Stack" table of the body
fix api_repos_acme_app_pulls_31 '{"number":31,"stack":null}'
fix pr_view_31_-R_acme_app_--json_body '{"body":"## Stack (part 2 of 3)\r\n| PR | Title | Base |\r\n|---|---|---|\r\n| #30 ✅ merged | a | main |\r\n| #31 | b | t1 |\r\n| #32 | c | t2 |\r\n\r\n## Follow-ups\r\n| #99 | x | y |"}'
fix "pr_view_30_-R_acme_app_$V" "$(slice 30 MERGED '"2026-01-01T00:00:00Z"' 30 t1 main a1)"
fix "pr_view_31_-R_acme_app_$V" "$(slice 31 OPEN null 31 t2 t1 a2)"
fix "pr_view_32_-R_acme_app_$V" "$(slice 32 OPEN null 32 t3 t2 a3)"
run "$main" stack 31
check "table stack: rows in order, only the Stack section, a (part N of M) heading, CRLF body" has '([.slices[].number] == [30,31,32]) and .stacked and .position == 2'
check "table stack: no native number, labelled by its bottom" has '.stack_num == null and .label == "stack of #30" and .slices[0].state == "merged"'

# --- fallback: the base-branch chain, by branch name
fix pr_list_-R_acme_app_--head_c2_--state_all_--json_number '[{"number":41}]'
fixerr api_repos_acme_app_stacks_41 'gh: Not Found (HTTP 404)'
fix api_repos_acme_app_pulls_41 '{"number":41,"stack":null}'
fix pr_view_41_-R_acme_app_--json_body '{"body":"## Stack\nPart 2 of 3"}'
fix "pr_view_40_-R_acme_app_$V" "$(slice 40 OPEN null 40 c1 main b1)"
fix "pr_view_41_-R_acme_app_$V" "$(slice 41 OPEN null 41 c2 c1 b2)"
fix "pr_view_42_-R_acme_app_$V" "$(slice 42 OPEN null 42 c3 c2 b3)"
fix pr_list_-R_acme_app_--head_c1_--state_all_--json_number_baseRefName_state '[{"number":40,"baseRefName":"main"}]'
fix pr_list_-R_acme_app_--base_c2_--state_open_--json_number_headRefName '[{"number":42,"headRefName":"c3"}]'
fix pr_list_-R_acme_app_--base_c3_--state_open_--json_number_headRefName '[]'
run "$main" stack c2
check "chain stack from a branch name: walks down and up" has '([.slices[].number] == [40,41,42]) and .anchor_pr == 41 and .position == 2 and .label == "stack of #40"'
fix pr_list_-R_acme_app_--base_c3_--state_open_--json_number_headRefName '[{"number":43,"headRefName":"x"},{"number":44,"headRefName":"y"}]'
run "$main" stack c2
check "a fork in the chain stops" has '.status == "stop" and (.message | contains("Cannot reconstruct a linear stack"))'
fix pr_list_-R_acme_app_--head_nope_--state_all_--json_number '[]'

# --- the chain and long-lived branches
L=--state_all_--json_number_baseRefName_state
for n in 50 51 52; do
  fixerr "api_repos_acme_app_stacks_$n" 'gh: Not Found (HTTP 404)'
  fix "api_repos_acme_app_pulls_$n" "{\"number\":$n,\"stack\":null}"
  fix "pr_view_${n}_-R_acme_app_--json_body" '{"body":""}'
done
fix "pr_view_50_-R_acme_app_$V" "$(slice 50 OPEN null 50 f1 develop d1)"
fix "pr_list_-R_acme_app_--head_develop_$L" '[{"number":1,"baseRefName":"main","state":"MERGED"},{"number":2,"baseRefName":"main","state":"MERGED"}]'
fix pr_list_-R_acme_app_--base_f1_--state_open_--json_number_headRefName '[]'
run "$main" stack 50
check "a base that was the head of several PRs, none open, is not a slice" has '.status == "ok" and .stacked == false and ([.slices[].number] == [50])'
fix "pr_view_51_-R_acme_app_$V" "$(slice 51 OPEN null 51 main develop d2)"
run "$main" stack 51
check "a head named like the default branch is not walked up from" has '.status == "ok" and .stacked == false'
fix "pr_view_52_-R_acme_app_$V" "$(slice 52 OPEN null 52 f2 lng d3)"
fix "pr_view_54_-R_acme_app_$V" "$(slice 54 OPEN null 54 lng main d4)"
fix "pr_list_-R_acme_app_--head_lng_$L" '[{"number":53,"baseRefName":"main","state":"CLOSED"},{"number":54,"baseRefName":"main","state":"OPEN"}]'
fix pr_list_-R_acme_app_--base_f2_--state_open_--json_number_headRefName '[]'
run "$main" stack 52
check "of several PRs from a base, the one open is followed" has '[.slices[].number] == [54,52]'
fix "pr_list_-R_acme_app_--head_lng_$L" '[{"number":53,"baseRefName":"main","state":"OPEN"},{"number":54,"baseRefName":"main","state":"OPEN"}]'
run "$main" stack 52
check "several open PRs from a base stop" has '.status == "stop" and (.message | contains("Cannot reconstruct a linear stack"))'

run "$main" stack nope
check "a branch without a PR stops" has '.status == "stop" and .message == "No PR for `nope`."'

# --- stack mode, empty anchor: the current branch's PR
fix wt-s2/pr_view_--json_number '{"number":12}'
run "$wt" stack
check "empty anchor: the current branch's PR" has '.anchor_pr == 12 and .stack_num == 7'

# --- target mode: splitting the first word
T=(target --command pr-fix --needs head --pushes --moves)
run "$wt" "${T[@]}" -- 12
check "a number is the target" has '.status == "ok" and .given == true and .target == "acme/app#12" and .anchor_pr == 12 and .dir == null'
run "$wt" "${T[@]}" -- 7
check "a stack number is the target; any stack branch serves head" has '.given == true and .anchor_pr == null and .target == "acme/app#7" and .dir == null'
fix wt-s2/pr_view_--json_number_state_url '{"number":12,"state":"OPEN","url":"https://github.com/acme/app/pull/12"}'
run "$wt" "${T[@]}" -- skip
check "a first word that is no target: the current branch's open PR, given false" has '.given == false and .target == "acme/app#12" and .position == 2 and .dir == null'
run "$wt" "${T[@]}"
check "no arguments: the same" has '.given == false and .target == "acme/app#12"'
run "$wt" "${T[@]}" -- '#13'
check "#N is the number N" has '.given == true and .target == "acme/app#13"'
run "$wt" "${T[@]}" -- 'app#13'
check "REPO#N stops, it is not read as no target" has '.status == "stop" and (.message | contains("OWNER/REPO#N"))'
fix repo_view_Acme_App_--json_nameWithOwner '{"nameWithOwner":"acme/app"}'
run "$wt" "${T[@]}" -- Acme/App#12
check "a typed repo in another case is this checkout's repo" has '.status == "ok" and .repo == "acme/app" and .dir == null'

# --- target mode: malformed calls stop with a message
run "$wt" "${T[@]}" -- '' --candidate acme/app#12
check "options after the first word stop" has '.status == "stop" and (.message | contains("before `--`"))'
run "$wt" "${T[@]}" --bogus -- 12
check "an unknown option stops" has '.status == "stop" and (.message | contains("--bogus"))'
run "$wt" "${T[@]}" --candidate
check "an option without its value stops" has '.status == "stop" and (.message | contains("--candidate needs a value"))'

# --- target mode: the session's PRs when the branch has no open PR
fixerr app/pr_view_--json_number_state_url 'no pull requests found for branch "main"'
fix pr_view_12_-R_acme_app_--json_state_author '{"state":"OPEN","author":{"login":"me"}}'
fix pr_view_13_-R_acme_app_--json_state_author '{"state":"OPEN","author":{"login":"someone"}}'
fix pr_view_11_-R_acme_app_--json_state_author '{"state":"MERGED","author":{"login":"me"}}'
fix api_user '{"login":"me"}'
run "$main" "${T[@]}"
check "no candidates: stop" has '.status == "stop" and .message == "No PR for the current branch."'
run "$main" "${T[@]}" --candidate acme/app#11 --candidate acme/app#13
check "a pusher keeps only open PRs of its own; the stop names the others" has '.status == "stop" and (.message | contains("acme/app#11 (merged)")) and (.message | contains("acme/app#13 (not yours)"))'
run "$main" "${T[@]}" --candidate acme/app#11 --candidate acme/app#12 --candidate acme/app#13
check "one candidate left: picked, said, and moved to its worktree" has ".given == false and .target == \"acme/app#12\" and .dir == \"$wt\" and (.notes[0] | contains(\"using \`acme/app#12\` from this session\"))"
check "moving says how to run commands and subagents" has ".notes | any(contains(\"cd $wt && \")) and any(contains(\"subagent\"))"
run "$main" target --command review-stack --needs top --candidate acme/app#12 --candidate acme/app#13
check "a command that does not push keeps others' PRs; two left: ask" has '.status == "ask" and .candidates == ["acme/app#12","acme/app#13"]'
check "ask exits 0" [ "$rc" -eq 0 ]
check "ask says to re-run with the chosen PR as the only candidate" has '.message | contains("as the only --candidate and the same first word")'
run "$main" target --command pr-triage --needs any --candidate acme/app#13 -- high
check "that re-run keeps the first word out of the target" has '.status == "ok" and .given == false and .target == "acme/app#13"'
fixerr app/pr_view_--json_number_state_url 'HTTP 401: Bad credentials'
run "$main" "${T[@]}" --candidate acme/app#12
check "a failed lookup is never read as no PR" has '.status == "stop" and (.message | contains("401"))'
fix app/pr_view_--json_number_state_url '{"number":11,"state":"MERGED","url":"https://github.com/acme/app/pull/11"}'
rm "$GH_FIX/app/pr_view_--json_number_state_url.err"
run "$main" "${T[@]}" --candidate acme/app#12
check "a merged PR on the current branch falls through to the candidates" has '.target == "acme/app#12"'

# --- target mode: the checkout
run "$main" "${T[@]}" -- 12
check "head, on another branch: move to the worktree on a stack branch" has ".dir == \"$wt\""
run "$main" target --command pr-triage --needs any --moves -- 12
check "any: every checkout of the repo is usable" has '.status == "ok" and .dir == null'
run "$other" target --command pr-triage --needs any --moves --checkout "$main" -- acme/app#12
check "any, from another repo: the first worktree of a checkout the session used" has ".dir == \"$main\""
run "$other" target --command pr-triage --needs any --moves -- acme/app#12
check "another repo and no known checkout: stop" has '.status == "stop" and (.message | contains("from a checkout of `acme/app`")) and (.message | contains(" on ") | not)'
run "$wt" target --command review-stack --needs top -- 7
check "top, on a lower slice, never moves: stop naming the command and the top branch" has '.status == "stop" and (.message | contains("/plan-lifecycle:review-stack acme/app#7")) and (.message | contains("on `s3`"))'
g -C "$main" checkout -q s3
run "$main" target --command review-stack --needs top -- 7
check "top, on the top branch: usable" has '.status == "ok" and .dir == null'
run "$wt" target --command review-stack --needs top -- 7
check "top, never moves, a worktree has it: stop naming that worktree" has ".status == \"stop\" and (.message | contains(\"from \`$main\`\"))"
g -C "$main" checkout -q --detach s3
run "$main" target --command review-stack --needs top -- 7
check "a detached HEAD at the top's head serves a command that does not push" has '.status == "ok" and .dir == null'
run "$main" target --command pr-fix --needs top --pushes -- 7
check "but not one that pushes" has '.status == "stop"'
run "$wt" target --command pr-fix --needs head --pushes --moves -- 20
check "unstacked PR whose head no worktree has: stop naming the branch" has '.status == "stop" and (.message | contains("on `solo`"))'
fix api_repos_acme_app_stacks_8 "{\"pull_requests\":[$(pr 20 open null 20 solo abc main)]}"
run "$wt" "${T[@]}" -- 8
check "a stack number whose stack has one PR: its head is the wanted branch" has '.status == "stop" and (.message | contains("on `solo`"))'
fix pr_list_-R_acme_app_--base_c3_--state_open_--json_number_headRefName '[]'
run "$wt" target --command review-stack --needs top -- 41
check "a stack without a native number has a top too" has '.status == "stop" and (.message | contains("on `c3`"))'

exit "$fail"
