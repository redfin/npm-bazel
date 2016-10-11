#!/bin/bash

SRCS_DIR=$1
NODE_MODULES_TAR=$2
OUTPUT_FILE=$3
SHARED_NODE_MODULES_TAR=${4:-} # optional

source "$0.runfiles/redfin_main/tools/scriptenv.sh"

SRCS_DIRNAME=$(basename "$SRCS_DIR")
OUTPUT_TMP_PKGDIR=$OUTPUT_TMP/$SRCS_DIRNAME/build

# skip tests in npm modules during pack. This requires cooperation
# from the package.json files.
export BZL_SKIP_TESTS=true
export BZL_SKIP_COVERAGE=true

cd $OUTPUT_TMP

cd - > /dev/null

# TODO: adding the extra directory between the shared node_modules
# and the package build directory makes sense for redfin.npm packages
# that use relative paths to find the shared node_modules at build time.
# this won't work for corvair and stingrayStatic if they start to use
# relative paths, because they're only one level deep.
mkdir -p $OUTPUT_TMP_PKGDIR

# rsync sources
rsync --archive --copy-unsafe-links --link-dest=$START_DIR/$SRCS_DIR $START_DIR/$SRCS_DIR/ "$OUTPUT_TMP_PKGDIR/"

cd $OUTPUT_TMP_PKGDIR

"$SNZIP" -dc < "$START_DIR/$NODE_MODULES_TAR" | "$GTAR" x

if [ -f extra-bazel-script ]; then
	./extra-bazel-script
fi

for stem in git npm
do
        if [ -f .${stem}ignore ]; then
                # break hard link, so we don't modify source files
                cp -p .${stem}ignore ${stem}ignore
                mv -f ${stem}ignore .${stem}ignore
        fi
done

if [[ "$PACK_TYPE" =~ (npm|all) ]]
then
        echo >> .npmignore
        echo `basename $NODE_MODULES_TAR` >> .npmignore

        npm --cache=$START_DIR/bazel-npm-cache pack

        PACK_TMP=../../pack-npm.tar.gz
        NPM_PACK_TMP=$PACK_TMP
        mv *.tgz "$PACK_TMP"
fi

if [[ "$PACK_TYPE" =~ (tar|all) ]]
then

        : > .gitignore
        echo .gitignore >> .gitignore
        echo node_modules >> .gitignore

        if [ -f .npmignore ]
        then
                # strip leading/trailing slashes to get similar behavior when npmignore
                # is intrepreted as gitignore by `tar --exclude-vcs-ignores`
                perl -pe 's@^/*(.*?)/*$@$1@' < .npmignore >> .gitignore
        fi

        "$JQ" -e .scripts.prepublish package.json > /dev/null && npm run prepublish

        PACK_TMP="../../$(basename "$OUTPUT_FILE")"
        GTAR_PACK_TMP=$PACK_TMP
        "$GTAR" --exclude-vcs-ignores \
                --exclude node_modules \
                --transform='s/^\./package/' \
                -c . \
        | case "$OUTPUT_FILE" in
                *.sz) "$SNZIP" ;;
                *.gz) gzip ;;
        esac > "$GTAR_PACK_TMP"

fi

if [ "$PACK_TYPE" = all ]
then
        lsgtar() {
                case "$GTAR_PACK_TMP" in
                        *.gz) gunzip ;;
                        *.sz) "$SNZIP" -dc ;;
                esac < "$GTAR_PACK_TMP" |
                        "$GTAR" t
        }
        if ! diff -u \
                <(lsgtar | sed '/\/$/d' | sort) \
                <("$GTAR" tzf $NPM_PACK_TMP | sed '/\/$/d' | sort)
        then
                exit 1
        fi
fi

mv "$PACK_TMP" "$START_DIR/$OUTPUT_FILE"


