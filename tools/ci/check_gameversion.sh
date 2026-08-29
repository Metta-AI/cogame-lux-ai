#!/bin/bash
# Fails when a PR reuses a GameVersion the base branch has ALREADY spent for a
# DIFFERENT rule.
#
# Why this exists: a GameVersion is claimed across BRANCHES, and nothing else in
# the build enforces that. Two branches can each be perfectly current with main
# and still pick the same next number, because neither can see the other's
# choice. The collision then lands silently, and a replay's recorded version no
# longer identifies the rules that produced it — the replay still LOADS (the
# version string matches) and then re-simulates wrong, which is worse than a
# refusal. See AGENTS.md, "A GameVersion number is claimed across BRANCHES".
#
# The non-obvious part: comparing the NUMBER cannot detect the collision,
# because the colliding branch and the base BOTH read e.g. "42". What
# distinguishes them is the RULE the number is attached to — the headline on the
# changelog comment. So: same number + different rule headline = two meanings
# for one version = fail.
#
# Usage:
#   tools/ci/check_gameversion.sh <base-ref> [head-ref]
# Examples:
#   tools/ci/check_gameversion.sh origin/main            # check working HEAD
#   tools/ci/check_gameversion.sh origin/main my-branch  # check a branch
#
# Exit 0 = fine, exit 1 = collision (or the branch is behind its base).
set -uo pipefail

BASE="${1:?usage: check_gameversion.sh <base-ref> [head-ref]}"
HEAD_REF="${2:-HEAD}"
CONST_FILE="src/lux/sim_types.nim"

line() {
  # The GameVersion declaration line from one ref, or empty if unreadable.
  git show "$1:$CONST_FILE" 2>/dev/null | grep -m1 'GameVersion\* ='
}
ver()  { line "$1" | grep -o '"[0-9]*"' | tr -d '"'; }

# rule <ref> <version>: the changelog headline that version is attached to on
# that ref, flattened to one line (the entry wraps across several).
#
# The changelog is a PREPEND-ONLY doc-comment BLOCK below the declaration, not
# a trailing comment on it, so this scans the block for the `GVnn (rule):`
# entry whose number matches. Reading the declaration line itself instead —
# which is what a `sed 's/.*## //'` on it degrades to, since there is no `##`
# there to cut at — hands back the same string for every ref, and the
# equal-numbers branch below then compares that string to itself and reports
# "no rule change claimed" for every collision it exists to catch.
rule() {
  git show "$1:$CONST_FILE" 2>/dev/null | awk -v want="GV$2 (" '
    !started { if ($0 ~ /GameVersion\* =/) started = 1; next }
    $0 !~ /^[[:space:]]*##/ { exit }                  # end of the block
    { text = $0; sub(/^[[:space:]]*##[[:space:]]?/, "", text) }
    capturing && (text == "" || text ~ /^GV[0-9]+ \(/) { exit }  # entry ended
    index(text, want) == 1 { capturing = 1 }
    capturing { out = (out == "" ? text : out " " text) }
    END { print out }
  '
}

base_v=$(ver "$BASE"); head_v=$(ver "$HEAD_REF")

if [ -z "$base_v" ] || [ -z "$head_v" ]; then
  echo "::error::could not read GameVersion from $CONST_FILE" \
       "(base='$BASE' -> '${base_v:-?}', head='$HEAD_REF' -> '${head_v:-?}')." \
       "If the const was renamed or the file moved, update" \
       "tools/ci/check_gameversion.sh."
  exit 1
fi

base_rule=$(rule "$BASE" "$base_v"); head_rule=$(rule "$HEAD_REF" "$head_v")

if [ -z "$base_rule" ] || [ -z "$head_rule" ]; then
  # Without a headline there is nothing to diff, and every check below would
  # compare "" with "" and pass. Refuse rather than go quietly blind.
  echo "::error::no 'GVnn (rule): HEADLINE' changelog entry in $CONST_FILE for" \
       "the version it declares (base='$BASE' GV$base_v ->" \
       "'${base_rule:-MISSING}', head='$HEAD_REF' GV$head_v ->" \
       "'${head_rule:-MISSING}'). Prepend one to the GameVersion doc comment:" \
       "the number is only meaningful with the rule it names."
  exit 1
fi

echo "base ($BASE) = GV$base_v — $base_rule"
echo "head ($HEAD_REF) = GV$head_v — $head_rule"

if [ "$head_v" -gt "$base_v" ]; then
  echo "OK: GV$head_v is above the base's GV$base_v."
  exit 0
fi

if [ "$head_v" -lt "$base_v" ]; then
  echo "::error::GV$head_v is BELOW the base's GV$base_v — this branch is" \
       "behind. Rebase onto $BASE, then re-derive any version-sensitive work" \
       "(the GameVersion const, replay fixtures) against the updated code."
  exit 1
fi

# Equal numbers. Fine only if this branch is not claiming a DIFFERENT rule —
# which is the overwhelmingly common case: every PR that does not touch the
# gameplay rules leaves both the number and the headline untouched.
if [ "$base_rule" = "$head_rule" ]; then
  echo "OK: GV$head_v unchanged from the base — no rule change claimed."
  exit 0
fi

echo "::error::GV$head_v is already spent on $BASE, for a DIFFERENT rule." \
     "Another branch merged your number first."
echo "  $BASE: $base_rule"
echo "  this branch: $head_rule"
echo "Renumber to GV$((base_v + 1)) — or higher, if an open PR claims that too;" \
     "AGENTS.md has a scan that lists every branch's claim — and RE-RECORD the" \
     "replay fixtures against the updated base. Fixtures cut against the old" \
     "number fail the replay version gate the moment the other change lands."
exit 1
