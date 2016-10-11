#! /bin/bash

# standard boilerplate for running a sandboxed script with access to features
# like statsd, an external progress logfile, and build tmpfs. To use in an
# action script, start with a block like:
#
# OUTPUT_FILE=...
# source "$0.runfiles/redfin_main/tools/scriptenv.sh"
#
# The sourcing script needs to set OUTPUT_FILE to the name of an output
# filename; this script will use that to choose a tempdir name and location.
# This script assumes that OUTPUT_FILE is the name of a bazel output in a
# package, and derives the package directory name from the dir portion of
# OUTPUT_FILE.
#
# When used in a test (eg. sh_test) target, the environment is different.
# OUTPUT_FILE is unnecessary, and this script should instead be sourced as:
#
# source "$TEST_SRCDIR.$TEST_WORKSPACE/tools/scriptenv.sh"

set -eu -o pipefail

if [ -z "${TEST_SRCDIR:-}" ]
then
        START_DIR=$(pwd -P)
        : ${RUNFILES:=$(cd "$0.runfiles" && pwd -P)}
        export RUNFILES
        export REDFIN_MAIN="$RUNFILES/redfin_main"
else
        OUTPUT_FILE=$0
        export RUNFILES=$TEST_SRCDIR
        export REDFIN_MAIN=$TEST_SRCDIR/$TEST_WORKSPACE
fi

OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
OUTPUT_DIRNAME=$(basename "$OUTPUT_DIR")

export GCP=$REDFIN_MAIN/compat_tools/bin/gcp; test -x "$GCP"
export GTAR=$REDFIN_MAIN/compat_tools/bin/gtar; test -x "$GTAR"
export JQ=$REDFIN_MAIN/compat_tools/bin/jq; test -x "$JQ"
export RDFIND=$REDFIN_MAIN/compat_tools/bin/rdfind; test -x "$RDFIND"
export SNZIP=$REDFIN_MAIN/compat_tools/bin/snzip; test -x "$SNZIP"

OUTPUT_TMP=$OUTPUT_DIR.$$
rm -rvf "$OUTPUT_TMP"
install -d -m 0755 "$OUTPUT_TMP"
OUTPUT_TMP="$( ( cd "$OUTPUT_TMP" && pwd -P ) )"
export BABEL_CACHE_PATH=$OUTPUT_TMP/.babel-cache.json

# set up node and npm paths.
# The node runtime is selected based on an alias+select in node_version_select/BUILD.
# There should only be one node runtime associated with a particular script.
# If there's not, that's going to cause problems.
# note that this will noop if the current target doesn't depend on
# //external:node and //external:node_headers
for dir in "$RUNFILES"/node_*
do
    test -d "$dir" && case "$dir" in
        */node_headers_*)
            NODE_HEADERS_DIR=$dir
            ;;
        */node_*)
            NODE_DIR=$dir
            ;;
    esac
done

test -n "${NODE_DIR:-}" && {
    echo "found node at $NODE_DIR"
    export PATH=$NODE_DIR/bin:$PATH
}

setup_node_gyp () {
    # PLAT-1700 extract headers into a process-specific directory
    # Someday we should fix PLAT-1701 and share node headers in a single dir
    mkdir -p /tmp/node-gyp.$$
    "$GTAR" xf $NODE_HEADERS_DIR/gyp-package.tar.gz -C /tmp/node-gyp.$$
}

set -x
