
BUILD_file = """
filegroup(
	name='raw',
	data= [f for f in glob(['**']) if '#' not in f],
	visibility=['//visibility:public']
)
"""

"""
This wrapper script replaces node 6.x's bin/npm symlink.

this is necessary for two reasons: 1) the sandbox presents symlinks to the
build process as regular files, which confuses npm, and 2) npm 3.x added new
behavior that modifies the PATH when scripts are called via `npm run`, which
broke our workaround for #1
"""
npm_script = """\
#!/bin/bash

DIR="$( dirname "${BASH_SOURCE[0]}" )"

$DIR/../lib/node_modules/npm/bin/npm-cli.js "$@"
"""

"""
This wrapper script replaces node 4.3.1's bin/npm symlink.

The node 4.3.1 version of npm-cli.js is actually a hybrid shell script/JS script
that execs "`dirname $0`/node <path to npm-cli.js>". Executing `node` directly
bypasses the need for the node and npm executables to live in the same
directory.
"""
npm_script_4_3_1 = """\
#!/bin/bash

DIR="$( dirname "${BASH_SOURCE[0]}" )"
node $DIR/../lib/node_modules/npm/bin/npm-cli.js "$@"
"""

def _node_binary_impl(repository_ctx):

	repository_ctx.file("BUILD", BUILD_file)


	version = repository_ctx.attr.version
	extension = repository_ctx.attr.extension

	# yes, bazel really prints "mac os x"... ¯\_(ツ)_/¯
	platform = "darwin" if repository_ctx.os.name == "mac os x" else repository_ctx.os.name

	if platform not in repository_ctx.attr.shas:
		fail("/tools/node_repository_rules.bzl: unsupported platform '{platform}'".format(platform=platform))

	sha = repository_ctx.attr.shas[platform]

	url = 'https://nodejs.org/download/release/v{version}/node-v{version}-{platform}-x64.{extension}'.format(
		version = repository_ctx.attr.version,
		platform = platform,
		extension = extension,
	)

	stripPrefix = 'node-v{version}-{platform}-x64'.format(
		version = version,
		platform = platform
	)

	repository_ctx.download_and_extract(
		url,
		repository_ctx.path("."), # extract into the root of this new repository
		sha,
		extension,
		stripPrefix,
	)

	# remove the bin/npm symlink and replace it with a shell script
	# that calls the previously-linked script. see comment on `npm_script`
	# assignment for more info.
	repository_ctx.execute(
		[ repository_ctx.which("rm"), repository_ctx.path("bin/npm") ]
	)

	repository_ctx.file(
		repository_ctx.path("bin/npm"),
		npm_script_4_3_1 if version == '4.3.1' else npm_script,
		True, #executable
	)

	return None

_node_binary = repository_rule(
	_node_binary_impl,
	local=False,
	attrs = {
		'version'   : attr.string(mandatory=True),
		'shas'      : attr.string_dict(mandatory=True, allow_empty=False),
		'extension' : attr.string(mandatory=True),
	},
)


def _node_headers_impl(repository_ctx):

	version = repository_ctx.attr.version
	sha = repository_ctx.attr.sha

	repository_ctx.file("BUILD", r"""
genrule(
	name='gyp-package',
	srcs=glob(['**']),
	outs=['gyp-package.tar.gz'],
	visibility=['//visibility:public'],
	cmd='''
rm -rf $(@D)/.node-gyp
mkdir -p $(@D)/.node-gyp
cp -r external/node_headers_{version_safe}/node-v{version} $(@D)/.node-gyp/{version}
echo 9 > $(@D)/.node-gyp/{version}/installVersion
tar zcf $@ -C $(@D) .node-gyp
'''
)
""".format(
	version = version,
	version_safe = version.replace('.', '_')
))

	url = 'https://nodejs.org/download/release/v{version}/node-v{version}-headers.tar.gz'.format(
		version = repository_ctx.attr.version,
	)

	repository_ctx.download_and_extract(
		url,
		repository_ctx.path("."), # extract into the root of this new repository
		sha,
		# specifying 'type' and 'stripPrefix' to work around https://github.com/bazelbuild/bazel/issues/1426
		'', # type
		'', # stripPrefix
	)

	return None


_node_headers = repository_rule(
	_node_headers_impl,
	local=False,
	attrs = {
		'version'   : attr.string(mandatory=True),
		'sha'       : attr.string(mandatory=True),
	},
)




def node_binary(version, shas, extension='tar.gz'):
	_node_binary(
		name = 'node_%s' % version.replace('.', '_'),
		version = version,
		shas = shas,
		extension = extension,
	)

def node_headers(version, sha):
	_node_headers(
		name = 'node_headers_%s' % version.replace('.', '_'),
		version = version,
		sha = sha,
	)
