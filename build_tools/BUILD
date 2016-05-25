py_binary(
	name='install_npm_dependencies',
	srcs=['install_npm_dependencies.py'],
	data=['npm_version_cache'],
	visibility = ['//visibility:public'],
)

sh_binary(
	name='npm_installer',
	srcs=['npm_installer.sh'],
	data=['install_npm_dependencies', '@node//:raw', '@node_headers//:gyp-package'],
	visibility = ['//visibility:public'],
)

sh_binary(
	name='npm_packer',
	srcs=['npm_packer.sh'],
	data=['@node//:raw'],
	visibility = ['//visibility:public'],
)

filegroup(
	name='npm_cache',
	srcs=['npm_version_cache'],
	visibility = ["//visibility:public"],
)
