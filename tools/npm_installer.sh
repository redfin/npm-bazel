#!/bin/bash

PACKAGE_FILE=$1
INTERNAL_MODULES_FILE=$2
NODE_MODULES_OUTPUT=$3

OUTPUT_FILE=$NODE_MODULES_OUTPUT

source "$0.runfiles/redfin_main/tools/scriptenv.sh"

OUTPUT_TMP_PKGDIR=$OUTPUT_TMP/$OUTPUT_DIRNAME

setup_node_gyp

$REDFIN_MAIN/tools/install_npm_dependencies.py "$PACKAGE_FILE" "$OUTPUT_TMP_PKGDIR" "$INTERNAL_MODULES_FILE"

"$RDFIND" -makehardlinks true -makeresultsfile false "$OUTPUT_TMP_PKGDIR/node_modules" > /dev/null

cd "$OUTPUT_TMP_PKGDIR"
HOME=/tmp/node-gyp.$$ \
npm --cache=$START_DIR/bazel-npm-cache rebuild > /dev/null
rm -rf /tmp/node-gyp.$$
cd - > /dev/null

"$GTAR" -C "$OUTPUT_DIR" --exclude __init__.py -c . | "$GTAR" -C "$OUTPUT_TMP" -x

"$GTAR" -c -C "$OUTPUT_TMP_PKGDIR" node_modules | "$SNZIP" -c > "$START_DIR/$NODE_MODULES_OUTPUT"
