
def _get_transitive_deps(deps):
	internal = []
	external = []
	for dep in deps:
		if dep.internal:
			internal.append(dep)
		else:
			external.append(dep)
		external.extend(dep.transitive_external_deps)
		internal.extend(dep.transitive_internal_deps)
	return struct( internal = internal, external = external );



def _internal_npm_module_impl(ctx):
	"""
	Implementation of `internal_npm_module` rule.
	- Builds and writes json_to_tarball.json file containing
	  a map of package.json location --> tarball location for
	  all transitive npm module dependencies
	-
	"""

	transitive_deps = _get_transitive_deps(ctx.attr.deps)
	transitive_dev_deps = _get_transitive_deps(ctx.attr.dev_deps)

	dep_files = []

	for dep in transitive_deps.internal + transitive_deps.external + transitive_dev_deps.internal + transitive_dev_deps.external:
		dep_files.extend(list(dep.files))

	# this json_to_tarball_map, e.g. {"blah/package.json": {"internal": false, "tarball": "blah/blah.tgz"}}
	# is used by install_npm_dependencies
	json_to_tarball_path_map = {}
	for external_dep in transitive_deps.external + transitive_dev_deps.external:
		for json in external_dep.json_to_tarball_map:
			json_to_tarball_path_map[json] = struct(**{"internal": False, "tarball":external_dep.json_to_tarball_map[json]})
	for internal_dep in transitive_deps.internal + transitive_dev_deps.internal:
		json_to_tarball_path_map[internal_dep.package_json.path] = struct(**{"internal": True, "tarball":internal_dep.tarball.path})

	json_to_tarball_file = ctx.new_file("json_to_tarball.json")

	ctx.file_action(
		content = struct(**json_to_tarball_path_map).to_json(),
		output = json_to_tarball_file
	)

	ctx.action(
		executable = ctx.executable.install_tool,
		arguments = [
			ctx.file.package_json.path,
			json_to_tarball_file.path,
			ctx.outputs.node_modules.path,
		],
		inputs = dep_files + [ctx.file.package_json, json_to_tarball_file],
		outputs = [ctx.outputs.node_modules],
		progress_message = "npm installing " + ctx.label.name,
		#execution_requirements = { 'requires-network': '1' },
	)

	source_dir = ctx.file.package_json.dirname

	pack_inputs = ctx.files.srcs + [ctx.outputs.node_modules]

	pack_arguments = [
		source_dir,
		ctx.outputs.node_modules.path,
		ctx.outputs.tarball.path,
	]

	if ctx.attr.shared_node_modules:
		tsz = list(ctx.attr.shared_node_modules.files)[0]
		pack_inputs += [ tsz ]
		pack_arguments += [ tsz.path ]

	ctx.action(
		executable = ctx.executable.pack_tool,
		arguments = pack_arguments,
		inputs = pack_inputs,
		outputs = [ctx.outputs.tarball],
		env = { 'PACK_TYPE': ctx.attr.pack_type },
		progress_message = "npm packing " + ctx.label.name,
		#execution_requirements = { 'requires-network': '1' },
	)

	return struct(
		internal = True,
		files = set([ctx.outputs.tarball, ctx.file.package_json]),
		tarball = ctx.outputs.tarball,
		node_modules = ctx.outputs.node_modules,
		package_json = ctx.file.package_json,
		transitive_internal_deps = transitive_deps.internal,
		transitive_external_deps = transitive_deps.external,
	)

def _external_npm_module(ctx):
	# our task here is to fill up the files array with a list of files
	# and to build a json_to_tarball_map, like:
	# {"blah/package.json": "blah/blah.tgz"}
	# the install_npm_dependencies will use the map at install time
	files = []
	json_to_tarball_map = {}
	for dep in [ctx.attr.tarball] + ctx.attr.runtime_deps:
		dep_file = list(dep.files)[0]
		files.append(dep_file)
		package_file = ctx.new_file(dep_file.dirname + "/" + "package.json")
		json_to_tarball_map[package_file.path] = dep_file.path
		ctx.action(
			inputs = [dep_file],
			outputs = [package_file],
			executable = ctx.executable._tarball_package_extractor,
			arguments = [
				dep_file.path,
				package_file.path,
			],
			progress_message = "Extracting package.json for " + ctx.label.name,
		)
		files.append(package_file)

	return struct(
		internal = False,
		files = set(files),
		transitive_internal_deps = [],
		transitive_external_deps = [],
		json_to_tarball_map = json_to_tarball_map,
	)

# the `pack_type` argument is to support multiple ways of generating packed npm
# modules. This is because I'm not yet sure gtar emulation of `npm pack' is
# good enough. pack_type can be:
#
# - npm: use ordinary `npm pack`
# - tar: use `npm prepublish` + `gtar`
# - all: use both, and compare the results, failing if there is any difference
internal_npm_module = rule(
	implementation = _internal_npm_module_impl,
	attrs = {
		"compress": attr.string(default='sz'),
		"pack_type": attr.string(default='tar'),
		"package_json": attr.label(allow_files=True, single_file=True, mandatory=True),
		"shared_node_modules": attr.label(allow_files=True, single_file=True),
		"srcs": attr.label_list(allow_files=True),
		"dev_deps": attr.label_list(allow_files=True),
		"deps": attr.label_list(allow_files=True),
		"install_tool": attr.label(executable=True, allow_files=True,
			default=Label("//tools:npm_installer")),
		"pack_tool": attr.label(executable=True, allow_files=True,
			default=Label("//tools:npm_packer")),
	},
	outputs = {
		"tarball": "%{name}.tar.%{compress}",
		"node_modules": "%{name}_node_modules.tar.sz"
	}
)

external_npm_module = rule(
	implementation = _external_npm_module,
	attrs = {
		"tarball": attr.label(allow_files = True, single_file=True),
		"runtime_deps": attr.label_list(allow_files = True),
		"_tarball_package_extractor": attr.label(executable=True, allow_files=True,
			default=Label("//tools:tarball_package_extractor")),
	},
)

