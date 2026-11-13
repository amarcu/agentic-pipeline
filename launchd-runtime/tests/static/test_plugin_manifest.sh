#!/bin/bash
# Static checks: the plugin manifest describes the repo as it actually is.
#
# 2026-09-10: the repo became installable as a Claude Code plugin without
# moving a single skill — `.claude-plugin/plugin.json` names the fifteen
# top-level skill directories in its `skills` array, so the plugin loader and
# install.sh's symlinks read the same layout. The array is the price of not
# using `"skills": "."`, which would also load `_templates` (scaffolding, not
# a skill) as a sixteenth skill. These tests keep the array honest: a skill
# added or removed on disk has to move the manifest with it, or the plugin
# quietly ships a different set than the symlinks do.

# The skill set install.sh links, by the rule install.sh uses: a top-level
# directory holding a SKILL.md, excluding `_`-prefixed scaffolding.
_plugin_skills_on_disk() {
    local dir name
    for dir in "$REPO_ROOT"/skills/*/; do
        [[ -f "$dir/SKILL.md" ]] || continue
        name=$(/usr/bin/basename "$dir")
        [[ "$name" == _* ]] && continue
        # The manifest lists what is published. A skill that .gitattributes
        # keeps out of snapshots (`export-ignore`) is installed from a
        # checkout only, and must not be in the plugin.
        if /usr/bin/grep -qE "^skills/$name/[[:space:]]+export-ignore" "$REPO_ROOT/.gitattributes" 2>/dev/null; then
            continue
        fi
        echo "$name"
    done | /usr/bin/sort
}

test_plugin_manifest_skills_match_the_repo() {
    local declared on_disk
    declared=$("$JQ_BIN" -r '.skills[]' "$REPO_ROOT/.claude-plugin/plugin.json" 2>/dev/null \
                   | /usr/bin/sed 's|^\./skills/||' | /usr/bin/sort)
    on_disk=$(_plugin_skills_on_disk)

    if [[ "$declared" != "$on_disk" ]]; then
        echo "  FAIL: .claude-plugin/plugin.json 'skills' does not match the skill"
        echo "        directories on disk. Add or remove the entry to match:"
        /usr/bin/diff <(echo "$declared") <(echo "$on_disk") \
            | /usr/bin/sed 's/^/    /'
        return 1
    fi
    return 0
}

test_plugin_manifest_never_ships_scaffolding() {
    # `_templates` is the skeleton new skills are copied from. It has a
    # SKILL.md, so every glob over the repo has to exclude it by name.
    if "$JQ_BIN" -e '.skills[] | select(test("/_"))' "$REPO_ROOT/.claude-plugin/plugin.json" >/dev/null 2>&1; then
        echo "  FAIL: .claude-plugin/plugin.json ships a '_'-prefixed directory as a skill"
        return 1
    fi
    return 0
}

test_marketplace_entry_agrees_with_plugin_manifest() {
    local market="$REPO_ROOT/.claude-plugin/marketplace.json"
    local listed manifest_name
    listed=$("$JQ_BIN" -r '.plugins[].name' "$market" 2>/dev/null)
    manifest_name=$("$JQ_BIN" -r '.name' "$REPO_ROOT/.claude-plugin/plugin.json" 2>/dev/null)

    if [[ "$listed" != "$manifest_name" ]]; then
        echo "  FAIL: marketplace.json lists '$listed' but plugin.json is named '$manifest_name'"
        return 1
    fi
    if [[ "$("$JQ_BIN" -r '.plugins[].source' "$market" 2>/dev/null)" != "./" ]]; then
        echo "  FAIL: the marketplace entry must point at the repo root ('./') —"
        echo "        the plugin and the marketplace are the same checkout"
        return 1
    fi
    return 0
}
