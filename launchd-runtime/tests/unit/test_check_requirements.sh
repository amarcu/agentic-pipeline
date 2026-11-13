#!/bin/bash
# Unit tests for bin/check-requirements, the per-project host-tooling gate.
#
# The thing being pinned is the exit code, because that is what decides whether
# a worker is spent. Three of these came straight out of the night of
# 2026-09-07:
#
#   1. A repo with no manifest must exit 0. Every repo is unmigrated on the day
#      this lands, and a checker that treated absence as a failure would stop
#      the whole roster in one go.
#   2. An `advisory` manifest that fails must ALSO exit 0, and say so in a way
#      the caller can act on — StarBonk's CLAUDE.md already prescribes
#      "NO GATE — verify by reading" when the Unity CLI is absent, so blocking
#      there would refuse work the project says is fine to do.
#   3. A version the TOOL reports and this cannot parse is a WARNING, not a
#      failure: the tool is installed, only its self-report is unreadable, and
#      failing on that would block a night's work over a vendor's formatting
#      change. A minimum the MANIFEST gets wrong is the opposite — that line
#      checks nothing, so it fails the whole file (see the malformed-manifest
#      tests below, which came out of the review round on PR #35).
#
# Fixtures are fake binaries on a fake PATH and fake repos behind a fake
# repos.conf, so nothing here touches the network, a real checkout or a real
# install.

_req_setup() {
    TEST_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-req.XXXXXX)
    REQ_BIN="$RUNTIME_DIR/bin/check-requirements"
    REQ_ROOT="$TEST_TMP/repo"
    REQ_CONF="$TEST_TMP/repos.conf"
    REQ_TEMPLATES="$TEST_TMP/templates"
    /bin/mkdir -p "$REQ_ROOT/agent" "$TEST_TMP/bin" "$TEST_TMP/empty/agent" \
                  "$REQ_TEMPLATES"

    # A repo the map knows and one it does not, so the resolution failure is
    # exercised alongside the happy path.
    /bin/cat > "$REQ_CONF" <<EOF
ACTIVE_REPOS=("acme/fixture" "acme/empty")
get_repo_path() {
    case "\$1" in
        acme/fixture) echo "$REQ_ROOT" ;;
        acme/empty)   echo "$TEST_TMP/empty" ;;
        *)              echo "" ;;
    esac
}
EOF

    # Three fake tools: one whose --version parses, one too old, one whose
    # --version says nothing version-shaped at all.
    _req_tool newtool  'echo "newtool version 2.5.1 (2026-01-01)"'
    _req_tool oldtool  'echo "oldtool 1.4.9"'
    _req_tool mumbler  'echo "built from source, no version here"'
    _req_tool betatool 'echo "1.0.0-beta.8"'
}

_req_tool() {
    local name="$1" body="$2"
    /bin/cat > "$TEST_TMP/bin/$name" <<EOF
#!/bin/bash
$body
EOF
    /bin/chmod +x "$TEST_TMP/bin/$name"
}

_req_teardown() {
    /bin/rm -rf "$TEST_TMP"
}

# Write the fixture repo's manifest from stdin.
_req_manifest() {
    /bin/cat > "$REQ_ROOT/agent/requirements.conf"
}

# Run the checker against the fixture repo, on the fixture PATH. The templates
# directory is pointed at the fixture's own too — a test that fell through to
# the repo's real requirements-templates/ would pass or fail on whatever is
# staged there today.
_req_run() {
    REPOS_CONF="$REQ_CONF" REQUIREMENTS_TEMPLATES="$REQ_TEMPLATES" \
        PATH="$TEST_TMP/bin:$PATH" "$REQ_BIN" "$@" 2>&1
}

# Write a staged template for `$1` (owner/repo) from stdin.
_req_template() {
    /bin/cat > "$REQ_TEMPLATES/${1/\//-}.conf"
}

test_check_requirements_passes_a_satisfied_manifest_of_every_verb() {
    _req_setup
    local rc=0 out
    /bin/mkdir -p "$REQ_ROOT/sub"
    _req_manifest <<'EOF'
# Every verb the format defines, all satisfiable.
cmd newtool >=2.5
path sub                 # a directory beside the manifest
env REQ_FIXTURE_VAR
check /usr/bin/true
EOF

    out=$(REQ_FIXTURE_VAR=set _req_run acme/fixture)
    assert_exit 0 $? "a satisfied manifest exits 0" || rc=1
    assert_contains "$out" "REQ: acme/fixture ok" "and says so on one line" || rc=1
    assert_not_contains "$out" "MISSING" "with no failures listed" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_fails_a_missing_command_and_prints_its_hint() {
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
cmd newtool
cmd definitely-not-on-this-host   # hint: brew install the-thing # install: brew install the-thing
EOF

    out=$(_req_run acme/fixture)
    assert_exit 1 $? "a missing required command exits 1" || rc=1
    assert_contains "$out" "MISSING cmd definitely-not-on-this-host" || rc=1
    assert_contains "$out" "hint: brew install the-thing" \
        "the hint is what turns a failure into a next step" || rc=1
    assert_contains "$out" "REQ: acme/fixture missing=1 (definitely-not-on-this-host)" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_fails_a_version_below_the_floor() {
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
cmd oldtool >=2.0
EOF

    out=$(_req_run acme/fixture)
    assert_exit 1 $? "installed but too old is still missing" || rc=1
    assert_contains "$out" "MISSING cmd oldtool" || rc=1
    assert_contains "$out" "wanted >=2.0" "and the line says what it wanted" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_ranks_a_release_above_its_own_pre_releases() {
    # unity's gate needs 1.0.0-beta.8 or newer. A naive component compare pads
    # a bare 1.0.0 to (1,0,0,0) and reports the GA release as older than the
    # beta it succeeds — which would fail the gate on the very upgrade that
    # fixes it.
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
cmd betatool >=1.0.0-beta.8
EOF
    out=$(_req_run acme/fixture)
    assert_exit 0 $? "beta.8 satisfies >=beta.8" || rc=1

    _req_tool betatool 'echo "1.0.0-beta.5"'
    out=$(_req_run acme/fixture)
    assert_exit 1 $? "beta.5 does not" || rc=1

    _req_tool betatool 'echo "1.0.0"'
    out=$(_req_run acme/fixture)
    assert_exit 0 $? "and the 1.0.0 release outranks every beta of it" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_warns_rather_than_fails_on_an_unreadable_version() {
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
cmd mumbler >=3.0
EOF

    out=$(_req_run acme/fixture)
    assert_exit 0 $? "an unreadable --version must not block work" || rc=1
    assert_contains "$out" "warn    cmd mumbler" || rc=1
    assert_contains "$out" "version unreadable" || rc=1
    assert_contains "$out" "REQ: acme/fixture ok" "and the repo still reports ok" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_reports_missing_paths_env_vars_and_failing_checks() {
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
path ../a-sibling-that-is-not-there
env REQ_FIXTURE_UNSET_VAR
check /usr/bin/false
EOF

    out=$(REQ_FIXTURE_UNSET_VAR= _req_run acme/fixture)
    assert_exit 1 $? || rc=1
    assert_contains "$out" "MISSING path ../a-sibling-that-is-not-there" \
        "a path is resolved relative to the repo root, so ../sibling works" || rc=1
    assert_contains "$out" "MISSING env REQ_FIXTURE_UNSET_VAR" \
        "an empty variable is as missing as an unset one" || rc=1
    assert_contains "$out" "MISSING check /usr/bin/false" || rc=1
    assert_contains "$out" "missing=3" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_lets_an_advisory_failure_through_as_a_gate_downgrade() {
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
gate: advisory
cmd definitely-not-on-this-host   # hint: install the editor
EOF

    out=$(_req_run acme/fixture)
    assert_exit 0 $? "an advisory failure never blocks the work" || rc=1
    assert_contains "$out" "REQ: acme/fixture advisory missing=1" || rc=1
    assert_contains "$out" "gate=no-gate" \
        "the caller is told what to do instead: verify by reading" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_advisory_does_not_cover_a_failed_version_floor() {
    # Grok on PR #35, reproduced: StarBonk declares `gate: advisory` AND
    # `cmd unity >=1.0.0-beta.8`. A beta.5 CLI made the whole repo `advisory`,
    # exit 0, `gate=no-gate` — so work-on-task skipped the verify gate, and the
    # gate it skipped is `unity-gate`, the one thing that refuses beta.5. The
    # floor did not merely fail to protect: declaring it left the repo WEAKER
    # than declaring nothing, because no manifest at all would have let the
    # gate run and fail loudly.
    #
    # `advisory` is about ABSENCE. A tool installed below its floor is present
    # and untrustworthy, which is the case the floor was written for.
    _req_setup
    local rc=0 out
    _req_tool betatool 'echo "1.0.0-beta.5"'
    _req_manifest <<'EOF'
gate: advisory
cmd betatool >=1.0.0-beta.8   # hint: unity upgrade
EOF

    out=$(_req_run acme/fixture --quiet)
    assert_exit 1 $? "an advisory gate does not downgrade a failed version floor" || rc=1
    assert_contains "$out" "below-floor=betatool"         "and the line names the floor as the reason it did not downgrade" || rc=1
    assert_not_contains "$out" "gate=no-gate"         "the caller must not be told to skip the gate that catches this" || rc=1

    # The other half, unchanged: an ABSENT tool under the same gate still
    # downgrades, which is what StarBonk's CLAUDE.md prescribes.
    _req_manifest <<'EOF'
gate: advisory
cmd definitely-not-on-this-host
EOF
    out=$(_req_run acme/fixture --quiet)
    assert_exit 0 $? "an absent tool under an advisory gate still proceeds" || rc=1
    assert_contains "$out" "gate=no-gate" || rc=1

    # And a failed floor under the default gate reports the same field, so a
    # reader never has to know the gate to read the cause.
    _req_manifest <<'EOF'
cmd oldtool >=2.0
EOF
    out=$(_req_run acme/fixture --quiet)
    assert_exit 1 $? || rc=1
    assert_contains "$out" "below-floor=oldtool" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_reads_a_staged_template_when_the_checkout_has_none() {
    # Grok on PR #35: GameTwo and StarBonk are the two host gaps this whole
    # script exists to close, and neither checkout could take a commit on the
    # day the manifests were written — so both manifests were staged in
    # requirements-templates/ and nothing read them. Both repos reported
    # `no-manifest`, exit 0, and the feature shipped covering neither.
    _req_setup
    local rc=0 out
    _req_template acme/empty <<'EOF'
cmd newtool >=2.5
EOF

    out=$(_req_run acme/empty --quiet)
    assert_exit 0 $? "a template-covered repo is checked, not skipped" || rc=1
    assert_equal "REQ: acme/empty ok (template)" "$out"         "and says which file answered, so nobody debugs the checkout" || rc=1

    # It is a real check, not a rubber stamp: the same template failing fails.
    _req_template acme/empty <<'EOF'
cmd definitely-not-on-this-host
EOF
    out=$(_req_run acme/empty --quiet)
    assert_exit 1 $? "a template that fails on this host fails the repo" || rc=1
    assert_contains "$out" "(template)" "and still names its source" || rc=1

    # A repo with neither is still no-manifest — absence must not start
    # blocking work now that a second place is searched.
    /bin/rm -f "$REQ_TEMPLATES/acme-empty.conf"
    out=$(_req_run acme/empty --quiet)
    assert_exit 0 $? || rc=1
    assert_equal "REQ: acme/empty no-manifest" "$out" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_prefers_the_checkouts_own_manifest_over_a_template() {
    # A manifest belongs in the project's repo; the template is a fallback and
    # never a shadow. If a stale template could override the committed file,
    # the project would lose control of its own requirements.
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
cmd newtool
EOF
    _req_template acme/fixture <<'EOF'
cmd definitely-not-on-this-host
EOF

    out=$(_req_run acme/fixture --quiet)
    assert_exit 0 $? "the checkout's own manifest wins" || rc=1
    assert_equal "REQ: acme/fixture ok" "$out"         "and carries no (template) marker, because no template was read" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_all_names_the_repos_it_read_from_a_template() {
    # `make doctor` prints a table, not summary lines, so the (template) marker
    # has nowhere to go. Without a note, the one row a reader is most likely to
    # act on is the one whose source they cannot see.
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
cmd newtool
EOF
    _req_template acme/empty <<'EOF'
cmd newtool
EOF

    out=$(_req_run --all --quiet)
    assert_exit 0 $? || rc=1
    assert_contains "$out" "NOTE: 1 repo(s) checked against a staged template" || rc=1
    assert_contains "$out" "acme/empty" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_exits_zero_for_a_repo_with_no_manifest() {
    _req_setup
    local rc=0 out
    out=$(_req_run acme/empty)
    assert_exit 0 $? "absence must never block work — every repo starts here" || rc=1
    assert_equal "REQ: acme/empty no-manifest" "$out" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_exits_two_for_a_repo_outside_the_repos_conf_map() {
    _req_setup
    local rc=0 out
    out=$(_req_run acme/not-in-the-map)
    assert_exit 2 $? "an unresolvable repo is a usage error, not a missing dep" || rc=1
    assert_contains "$out" "get_repo_path" || rc=1
    _req_teardown
    return $rc
}

# ── Malformed manifests ───────────────────────────────────────────────────
#
# Copilot on PR #35, confirmed by reproduction: the first version of this
# checker reported `REQ: acme/bad ok` and exited 0 over a manifest whose
# `binary jq` line it had skipped, in every mode — the ERROR lines printed
# without --quiet, but the summary line and the exit code, which are what the
# skills act on, said everything was fine. A requirement written with a typo is
# a requirement silently not being checked, and reporting `ok` over one is the
# exact failure this whole system exists to remove. Every malformed shape below
# now fails the WHOLE check, before any probing, in every mode.

# Assert that a manifest fails as `manifest-error`, quietly and loudly alike.
_req_assert_manifest_error() {
    local needle="$1" msg="${2:-}" rc=0 out
    out=$(_req_run acme/fixture)
    assert_exit 1 $? "$msg: exits 1" || rc=1
    assert_contains "$out" "REQ: acme/fixture manifest-error" "$msg: names the failure" || rc=1
    assert_contains "$out" "$needle" "$msg: names the line" || rc=1

    out=$(_req_run acme/fixture --quiet)
    assert_exit 1 $? "$msg: --quiet exits 1 too" || rc=1
    assert_contains "$out" "manifest-error" "$msg: --quiet says why" || rc=1
    assert_contains "$out" "$needle" "$msg: --quiet names the line" || rc=1
    return $rc
}

test_check_requirements_fails_the_whole_check_on_an_unknown_verb() {
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
cmd newtool
binary newtool
EOF

    _req_assert_manifest_error "line 2: unknown verb 'binary'" "unknown verb" || rc=1
    # The clincher: the good line is not reported as checked either. A file
    # that does not say what it means cannot be trusted to be the whole list.
    out=$(_req_run acme/fixture)
    assert_not_contains "$out" "ok      cmd newtool" \
        "no requirement is probed once the file failed to parse" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_fails_the_whole_check_on_a_verb_with_no_argument() {
    _req_setup
    local rc=0
    _req_manifest <<'EOF'
cmd newtool
cmd
EOF

    _req_assert_manifest_error "line 2: 'cmd' needs an argument" "truncated line" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_fails_the_whole_check_on_a_malformed_version_spec() {
    # The manifest's own floor, not the tool's self-report. An unreadable
    # `--version` from the tool stays a warning (the tool IS installed); a
    # minimum nothing can be compared against means the line checks nothing.
    _req_setup
    local rc=0
    _req_manifest <<'EOF'
cmd newtool >=not-a-version
EOF

    _req_assert_manifest_error "'not-a-version' is not a version" "malformed version spec" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_refuses_every_cmd_spec_but_the_two_it_defines() {
    # Copilot on PR #35, round three. The parse this replaced threw the
    # operator away: it joined every token after the name and lstrip'd the
    # characters `>` and `=` off the front, so `<2.0` became `2.0` and was
    # evaluated as a MINIMUM — the exact opposite of what its author wrote —
    # and `>=2.92 and some junk` quietly swallowed the junk. A version
    # constraint that means the reverse of what it says is worse than none.
    _req_setup
    local rc=0 spec out

    for spec in "newtool <2.0" "newtool ==2.0" "newtool =>2.0" "newtool >2.0" \
                "newtool 2.0" "newtool >=2.0 and some junk"; do
        printf 'cmd %s\n' "$spec" > "$REQ_ROOT/agent/requirements.conf"
        out=$(_req_run acme/fixture --quiet)
        assert_exit 1 $? "'cmd $spec' is refused, not interpreted" || rc=1
        assert_contains "$out" "manifest-error" "'cmd $spec' says so" || rc=1
        assert_contains "$out" ">= is the only operator" "'cmd $spec' names the grammar" || rc=1
    done

    # And the two forms the format does define still work, with or without a
    # space after the operator.
    for spec in "newtool" "newtool >=2.0" "newtool >= 2.0"; do
        printf 'cmd %s\n' "$spec" > "$REQ_ROOT/agent/requirements.conf"
        out=$(_req_run acme/fixture --quiet)
        assert_exit 0 $? "'cmd $spec' is a legal spec" || rc=1
        assert_equal "REQ: acme/fixture ok" "$out" "'cmd $spec'" || rc=1
    done
    _req_teardown
    return $rc
}

test_check_requirements_evaluates_a_version_floor_as_a_floor() {
    # The proof that the operator is honoured rather than discarded: 1.4.9 is
    # below 2.0, so `>=2.0` must fail — and the spec that used to be silently
    # read as `>=2.0` must now not parse at all.
    _req_setup
    local rc=0
    printf 'cmd oldtool >=2.0\n' > "$REQ_ROOT/agent/requirements.conf"
    _req_run acme/fixture --quiet > /dev/null
    assert_exit 1 $? "1.4.9 does not satisfy >=2.0" || rc=1

    printf 'cmd oldtool >=1.0\n' > "$REQ_ROOT/agent/requirements.conf"
    _req_run acme/fixture --quiet > /dev/null
    assert_exit 0 $? "1.4.9 does satisfy >=1.0" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_fails_an_env_line_naming_more_than_one_variable() {
    # A variable name cannot hold a space, so `env A B` is always a typo. A
    # `path` can hold one (macOS is full of them) and a `check` is a whole
    # shell command, so neither gets this rule.
    _req_setup
    local rc=0
    _req_manifest <<'EOF'
env HOME PATH
EOF
    _req_assert_manifest_error "names more than one variable" "two-variable env line" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_fails_the_whole_check_on_a_bad_or_misplaced_gate() {
    _req_setup
    local rc=0
    _req_manifest <<'EOF'
gate: whenever
cmd newtool
EOF
    _req_assert_manifest_error "unknown gate 'whenever'" "unknown gate value" || rc=1

    _req_manifest <<'EOF'
cmd newtool
gate: advisory
EOF
    _req_assert_manifest_error "gate: must come before any requirement" "misplaced gate" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_manifest_error_is_not_softened_by_an_advisory_gate() {
    # `gate: advisory` says what to do when a requirement is ABSENT. It says
    # nothing about a file that cannot be read, and must not downgrade one.
    _req_setup
    local rc=0
    _req_manifest <<'EOF'
gate: advisory
binary newtool
EOF

    _req_assert_manifest_error "unknown verb 'binary'" "advisory + parse error" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_quiet_prints_only_the_summary_line() {
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
cmd newtool
EOF

    out=$(_req_run acme/fixture --quiet)
    assert_equal "REQ: acme/fixture ok" "$out" \
        "--quiet is what the skills call: one parsable line, no detail" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_json_carries_the_hint_and_install_annotations() {
    # install-requirements reads exactly these two fields; if they stop coming
    # through, it silently offers nothing.
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
cmd definitely-not-on-this-host  # hint: get it from somewhere # install: brew install thing
EOF

    out=$(_req_run acme/fixture --json | /usr/bin/python3 -c '
import json, sys
req = json.loads(sys.stdin.readline())["requirements"][0]
print("%s|%s|%s" % (req["status"], req["hint"], req["install"]))')
    assert_equal "missing|get it from somewhere|brew install thing" "$out" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_all_prints_a_table_and_a_total() {
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
cmd definitely-not-on-this-host
EOF

    out=$(_req_run --all --quiet)
    assert_exit 1 $? "--all fails when any repo fails — this is make doctor" || rc=1
    assert_contains "$out" "acme/fixture" || rc=1
    assert_contains "$out" "acme/empty" "every ACTIVE_REPOS entry gets a row" || rc=1
    assert_contains "$out" "TOTAL 2 repos: 0 ok, 1 missing" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_all_fails_and_counts_a_manifest_error() {
    _req_setup
    local rc=0 out
    _req_manifest <<'EOF'
binary newtool
EOF

    out=$(_req_run --all --quiet)
    assert_exit 1 $? "make doctor fails on an unreadable manifest" || rc=1
    assert_contains "$out" "manifest-error" || rc=1
    assert_contains "$out" "1 manifest-error" "and the total counts it separately" || rc=1
    _req_teardown
    return $rc
}

test_check_requirements_refuses_both_a_repo_and_all() {
    _req_setup
    local rc=0
    _req_run acme/fixture --all > /dev/null
    assert_exit 2 $? "one repo, or --all, never both" || rc=1
    _req_run > /dev/null
    assert_exit 2 $? "and neither is a usage error too" || rc=1
    _req_teardown
    return $rc
}
