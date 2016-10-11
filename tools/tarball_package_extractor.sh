#!/bin/bash
START_DIR=$(pwd -P)
: ${RUNFILES:=$START_DIR/${BASH_SOURCE[0]}.runfiles}
REDFIN_MAIN="$RUNFILES/redfin_main"
export GTAR=$REDFIN_MAIN/compat_tools/bin/gtar; test -x "$GTAR"
$GTAR -zx --wildcards --no-wildcards-match-slash --warning=no-unknown-keyword --to-stdout -f "$1" '*/package.json' > "$2"
