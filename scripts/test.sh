#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build
if [[ "${1:-}" == "--network" ]]; then
    test_dir="$(mktemp -d "${TMPDIR:-/tmp}/EchoTerm-tests.XXXXXX")"
    python3 scripts/mock-ai-server.py --port-file "$test_dir/port" &
    server_pid=$!
    trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$test_dir"' EXIT
    for attempt in {1..100}; do
        [[ -s "$test_dir/port" ]] && break
        sleep 0.05
    done
    [[ -s "$test_dir/port" ]] || { print 'Local SSE fixture failed to start'; exit 1; }
    export ECHOTERM_TEST_API="http://127.0.0.1:$(cat "$test_dir/port")/v1"
fi
"$(swift build --show-bin-path)/EchoTerm" --self-test
