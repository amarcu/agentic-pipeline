#!/bin/bash
# Tests for launchd-runtime/bin/jev-route — the shadow call that asks Jev which
# model tier an approved issue needs and logs the answer. What these pin: it
# never stops dispatch (exit 0 on every failure), it never prints or logs the
# key, and decide() picks the tier the thresholds say. Jev is a local server
# answering canned responses; gh is the suite's mock.

_jr_setup() {
    JR_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-jevroute.XXXXXX)
    export MOCK_GH_DIR="$JR_TMP/gh"
    export PATH="$FIXTURES_DIR/mock-gh:$PATH"
    /bin/mkdir -p "$MOCK_GH_DIR"
    /bin/cat > "$MOCK_GH_DIR/issue-7.json" <<'JSON'
{"title": "Log why a handshake is dropped", "body": "## Acceptance criteria\n- [ ] the drop is logged", "labels": [{"name": "approved"}]}
JSON
    JR_KEY="ts-test-key-do-not-print-0123456789"
    printf '%s\n' "$JR_KEY" > "$JR_TMP/api-key"
    /bin/chmod 600 "$JR_TMP/api-key"
    export TYPESAFE_API_KEY_FILE="$JR_TMP/api-key"
    unset TYPESAFE_API_KEY
    export GH_BIN="$FIXTURES_DIR/mock-gh/gh"
    JR_LEDGER="$JR_TMP/ledger.jsonl"

    # A one-request-at-a-time Jev: answers $JR_TMP/response.json with the status
    # in $JR_TMP/status, and records whether the Authorization header carried
    # the key — never the header itself.
    /bin/cat > "$JR_TMP/server.py" <<'PY'
import http.server, os, sys
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        expected = "Bearer " + open(os.path.join(root, "api-key")).read().strip()
        open(os.path.join(root, "auth.log"), "a").write(
            ("auth=ok" if self.headers.get("Authorization") == expected else "auth=bad") + "\n")
        status = int(open(os.path.join(root, "status")).read().strip())
        body = open(os.path.join(root, "response.json"), "rb").read()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(root, "port"), "w").write(str(srv.server_port))
srv.serve_forever()
PY
    echo 200 > "$JR_TMP/status"
    /usr/bin/python3 "$JR_TMP/server.py" "$JR_TMP" &
    JR_SERVER_PID=$!
    local i
    for i in $(seq 1 50); do [[ -s "$JR_TMP/port" ]] && break; /bin/sleep 0.1; done
    export JEV_API_URL="http://127.0.0.1:$(/bin/cat "$JR_TMP/port")/v1/systemone"
}

_jr_teardown() {
    kill "$JR_SERVER_PID" 2>/dev/null
    wait "$JR_SERVER_PID" 2>/dev/null
    /bin/rm -rf "$JR_TMP"
    unset MOCK_GH_DIR TYPESAFE_API_KEY_FILE GH_BIN JEV_API_URL
}

# _jr_answers clarity judgment breadth security area minconf — each score is
# given on 0-1 and written as a probability-weighted value over levels 0-3.
_jr_answers() {
    /usr/bin/python3 - "$JR_TMP/response.json" "$@" <<'PY'
import json, sys
path, c, j, b, s, area, conf = sys.argv[1], *map(float, sys.argv[2:6]), sys.argv[6], float(sys.argv[7])
legend = {"0": "a", "1": "b", "2": "c", "3": "d"}
def score(v):
    return {"type": "score", "score": v * 3, "legend": legend, "confidence": conf,
            "probabilities": {"0": 0.25, "1": 0.25, "2": 0.25, "3": 0.25}}
json.dump({"model": "jev-1.13.0", "usage": {"input_tokens": 1234, "output_tokens": 50}, "answers": {
    "clarity": score(c), "judgment": score(j), "breadth": score(b),
    "area": {"type": "choice", "choice": area, "confidence": conf, "probabilities": {area: conf}},
    "security": {"type": "noul", "noul": s}}}, open(path, "w"))
PY
}

_jr() { "$RUNTIME_DIR/bin/jev-route" acme/game 7 --run r1 --ledger "$JR_LEDGER"; }

test_jev_route_picks_sonnet_for_clear_local_mechanical_work() {
    _jr_setup
    local rc=0 out status
    _jr_answers 0.9 0.1 0.1 0.05 gameplay_ui 0.9
    out=$(_jr); status=$?
    assert_equal 0 "$status" || rc=1
    assert_contains "$out" "result=ok tier=sonnet" || rc=1
    assert_contains "$out" "tokens=1234" || rc=1
    assert_equal "auth=ok" "$(/bin/cat "$JR_TMP/auth.log")" "the key reached Jev as a bearer token" || rc=1
    _jr_teardown
    return $rc
}

test_jev_route_defaults_to_opus_and_escalates_open_design_to_fable() {
    _jr_setup
    local rc=0 out
    _jr_answers 0.9 0.5 0.6 0.05 gameplay_ui 0.9
    out=$(_jr)
    assert_contains "$out" "tier=opus" "some judgment and breadth is the default tier" || rc=1
    _jr_answers 0.9 0.9 0.6 0.05 gameplay_ui 0.9
    out=$(_jr)
    assert_contains "$out" "tier=fable" "open design decisions go to the strongest model" || rc=1
    _jr_teardown
    return $rc
}

test_jev_route_never_picks_sonnet_on_low_confidence_or_security() {
    _jr_setup
    local rc=0 out
    _jr_answers 0.9 0.1 0.1 0.05 gameplay_ui 0.4
    out=$(_jr)
    assert_contains "$out" "tier=opus" "low confidence falls back to the stronger model" || rc=1
    assert_contains "$out" "low confidence" || rc=1
    _jr_answers 0.9 0.1 0.1 0.9 gameplay_ui 0.9
    out=$(_jr)
    assert_contains "$out" "tier=opus" "a security-touching change is not sent to sonnet" || rc=1
    _jr_teardown
    return $rc
}

test_jev_route_logs_raw_answers_and_never_the_key() {
    _jr_setup
    local rc=0 out
    _jr_answers 0.9 0.1 0.1 0.05 gameplay_ui 0.9
    out=$(_jr)
    assert_equal 1 "$(/usr/bin/wc -l < "$JR_LEDGER" | /usr/bin/tr -d ' ')" "one ledger row per call" || rc=1
    assert_equal "gameplay_ui" "$("$JQ_BIN" -r '.answers.area.choice' "$JR_LEDGER")" "raw answers are kept for re-tuning" || rc=1
    assert_not_contains "$out$(/bin/cat "$JR_LEDGER")" "$JR_KEY" "the key is never printed or logged" || rc=1
    assert_not_contains "$out$(/bin/cat "$JR_LEDGER")" "Bearer" || rc=1
    _jr_teardown
    return $rc
}

test_jev_route_skips_without_a_usable_key_and_never_fails_dispatch() {
    _jr_setup
    local rc=0 out status
    _jr_answers 0.9 0.1 0.1 0.05 gameplay_ui 0.9
    export TYPESAFE_API_KEY_FILE="$JR_TMP/missing"
    out=$(_jr); status=$?
    assert_equal 0 "$status" "a missing key is not a failure" || rc=1
    assert_contains "$out" "result=skipped" || rc=1
    [[ -e "$JR_LEDGER" ]] && { echo "  FAIL: a skipped call writes no ledger row"; rc=1; }
    export TYPESAFE_API_KEY_FILE="$JR_TMP/api-key"
    /bin/chmod 640 "$JR_TMP/api-key"
    out=$(_jr); status=$?
    assert_equal 0 "$status" || rc=1
    assert_contains "$out" "result=skipped" || rc=1
    assert_contains "$out" "chmod 600" "a group-readable key file is refused, with the fix" || rc=1
    _jr_teardown
    return $rc
}

test_jev_route_reports_errors_but_exits_zero() {
    _jr_setup
    local rc=0 out status
    _jr_answers 0.9 0.1 0.1 0.05 gameplay_ui 0.9
    echo 529 > "$JR_TMP/status"
    out=$(_jr); status=$?
    assert_equal 0 "$status" "an overloaded Jev never stops dispatch" || rc=1
    assert_contains "$out" "result=error tier=-" || rc=1
    assert_contains "$out" "Jev HTTP 529" || rc=1
    echo 200 > "$JR_TMP/status"
    out=$("$RUNTIME_DIR/bin/jev-route" acme/game 99 --run r1 --ledger "$JR_LEDGER"); status=$?
    assert_equal 0 "$status" "an issue gh cannot fetch is not a failure either" || rc=1
    assert_contains "$out" "result=error" || rc=1
    assert_equal 2 "$(/usr/bin/wc -l < "$JR_LEDGER" | /usr/bin/tr -d ' ')" "errors are logged too" || rc=1
    "$RUNTIME_DIR/bin/jev-route" "not a repo" 7 >/dev/null 2>&1; status=$?
    assert_equal 2 "$status" "a malformed call is a usage error" || rc=1
    _jr_teardown
    return $rc
}
