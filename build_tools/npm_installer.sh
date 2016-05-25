#!/bin/bash -eux

START_DIR=`pwd`
RUNFILES=$START_DIR/${BASH_SOURCE[0]}.runfiles/__main__

PACKAGE_FILE=$1
INTERNAL_MODULES_FILE=$2
NODE_MODULES_OUTPUT=$3

OUTPUT_DIR=`dirname $NODE_MODULES_OUTPUT`
OUTPUT_NAME=`basename $NODE_MODULES_OUTPUT`

$RUNFILES/build_tools/install_npm_dependencies.py $PACKAGE_FILE $OUTPUT_DIR $INTERNAL_MODULES_FILE $RUNFILES/build_tools/npm_version_cache

safelink() {
	SRC=$1
	DEST=$2
	if [ ! -L $DEST ]; then
		mkdir -p `dirname $DEST`
		# On non-sandbox machines, there could be a race condition
		# Try creating the symlink, allowing failure
		set +e
		ln -s $SRC $DEST
		set -e
		# if the file's still not there, try it with halt-on-failure
		if [ ! -L $DEST ]; then
			ln -s $SRC $DEST
		fi
	fi
}

# the real npm is a symlink to npm-cli.js, but the runfiles npm is a hardlink? real file? whatever
safelink $RUNFILES/../node/bin/node /tmp/npm-bin/node
safelink $RUNFILES/../node/lib/node_modules/npm/bin/npm-cli.js /tmp/npm-bin/npm

export PATH=/tmp/npm-bin:$RUNFILES/../node/bin:$PATH

if [ ! -d /tmp/.node-gyp ]; then
	mkdir -p /tmp
	tar xf $RUNFILES/../node_headers/gyp-package.tar.gz -C /tmp
fi

cd $OUTPUT_DIR
HOME=/tmp npm --cache=$START_DIR/bazel-npm-cache rebuild
tar zcf $OUTPUT_NAME node_modules
