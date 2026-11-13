#!/bin/bash
# Static checks for bin/routine-contracts.tsv, the lines each scheduled
# routine's final message owes. The runner warns and the smoke gate fails on
# it (#52), so a routine missing from it is a routine nobody checks.

_CONTRACTS="$RUNTIME_DIR/bin/routine-contracts.tsv"

test_every_routine_prompt_has_a_contract_row() {
    local rc=0 prompt routine
    for prompt in "$RUNTIME_DIR"/prompts/*.md; do
        routine=$(/usr/bin/basename "$prompt" .md)
        if ! LC_ALL=C /usr/bin/awk -F'\t' -v r="$routine" '$1 == r {found=1} END {exit !found}' "$_CONTRACTS"; then
            echo "  FAIL: $routine has a prompt but no row in bin/routine-contracts.tsv (use - if it owes no line)"
            rc=1
        fi
    done
    return $rc
}

test_every_contract_row_names_a_real_routine() {
    local rc=0 routine
    while IFS= read -r routine; do
        if [[ ! -f "$RUNTIME_DIR/prompts/$routine.md" ]]; then
            echo "  FAIL: bin/routine-contracts.tsv names $routine, which has no prompt"
            rc=1
        fi
    done < <(LC_ALL=C /usr/bin/awk -F'\t' '!/^#/ && NF {print $1}' "$_CONTRACTS" | /usr/bin/sort -u)
    return $rc
}
