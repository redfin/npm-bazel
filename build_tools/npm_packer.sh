#!/bin/bash -eux

export START_DIR=`pwd`
RUNFILES=${RUNFILES:-}
if [ -z "$RUNFILES" ]; then
	RUNFILES=$START_DIR/${BASH_SOURCE[0]}.runfiles/__main__
fi

SRCS_DIR=$1
NODE_MODULES_TAR=$2
OUTPUT=$3

OUTPUT_DIR=`dirname $OUTPUT`

# the real npm is a symlink to npm-cli.js, but the runfiles npm is a hardlink? real file? whatever
mkdir -p /tmp/npm-bin
if [ ! -L /tmp/npm-bin/node ]; then
	ln -s $RUNFILES/../node/bin/node /tmp/npm-bin/node
fi
if [ ! -L /tmp/npm-bin/npm ]; then
	ln -s $RUNFILES/../node/lib/node_modules/npm/bin/npm-cli.js /tmp/npm-bin/npm
fi

export PATH=/tmp/npm-bin:$RUNFILES/../node/bin:$PATH

rsync --archive --copy-unsafe-links --link-dest=$START_DIR/$SRCS_DIR $START_DIR/$SRCS_DIR/ $START_DIR/$OUTPUT_DIR/

cd $OUTPUT_DIR

tar xf $START_DIR/$NODE_MODULES_TAR

if [ -f extra-bazel-script ]; then
	./extra-bazel-script
fi

if [ -f .npmignore ]; then
	# break hard link, so we don't modify source files
	cp .npmignore npmignore
	rm .npmignore
	mv npmignore .npmignore
fi

echo >> .npmignore
echo `basename $NODE_MODULES_TAR` >> .npmignore

npm --cache=$START_DIR/bazel-npm-cache pack

mv *.tgz $START_DIR/$OUTPUT
