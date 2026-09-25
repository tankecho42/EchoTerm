#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build-app.sh debug
open dist/EchoTerm.app --args "$@"
