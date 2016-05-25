def _internal_npm_module_impl(ctx):
	transitive_external_deps = []
	transitive_internal_deps = []
	transitive_internal_dev_deps = []
	transitive_external_dev_deps = []
	dep_files = []
	for dep in ctx.attr.deps:
		if dep.internal:
			transitive_internal_deps.append(dep)
		else:
			transitive_external_deps.append(dep)
		transitive_external_deps.extend(dep.transitive_external_deps)
		transitive_internal_deps.extend(dep.transitive_internal_deps)

	for dep in ctx.attr.dev_deps:
		if dep.internal:
			transitive_internal_dev_deps.append(dep)
		else:
			transitive_external_dev_deps.append(dep)
		transitive_external_dev_deps.extend(dep.transitive_external_deps)
		transitive_internal_dev_deps.extend(dep.transitive_internal_deps)

	for dep in transitive_external_deps + transitive_internal_deps + transitive_internal_dev_deps + transitive_external_dev_deps:
		dep_files.extend(list(dep.files))

	internal_modules = ctx.new_file("internal_modules.json")
	internal_deps = struct(**{
		dep.package_json.path: dep.tarball.path
			for dep in transitive_internal_deps + transitive_internal_dev_deps
	})
	for dep in transitive_internal_deps + transitive_internal_dev_deps:
		dep_files.append(dep.package_json)

	ctx.file_action(
		content=internal_deps.to_json() + '\n',
		output = internal_modules
	)

	ctx.action(
		executable = ctx.executable.install_tool,
		arguments = [
			ctx.file.package_json.path,
			internal_modules.path,
			ctx.outputs.node_modules.path,
		],
		inputs = dep_files + [ctx.file.package_json, internal_modules],
		outputs = [ctx.outputs.node_modules],
		progress_message = "npm installing " + ctx.label.name,
	)

	source_dir = ctx.file.package_json.dirname

	pack_inputs = ctx.files.srcs + [ctx.outputs.node_modules]

	ctx.action(
		executable = ctx.executable.pack_tool,
		arguments = [
			source_dir,
			ctx.outputs.node_modules.path,
			ctx.outputs.tarball.path,
		],
		inputs = pack_inputs,
		outputs = [ctx.outputs.tarball],
		progress_message = "npm packing " + ctx.label.name,
	)

	return struct(
		internal = True,
		tarball = ctx.outputs.tarball,
		package_json = ctx.file.package_json,
		transitive_internal_deps = transitive_internal_deps,
		transitive_external_deps = transitive_external_deps
	)

def _external_npm_module(ctx):
	return struct(
		internal = False,
		transitive_internal_deps = [],
		transitive_external_deps = [ctx.attr.raw_target] + ctx.attr.runtime_deps
	)

internal_npm_module = rule(
	implementation = _internal_npm_module_impl,
	attrs = {
		"package_json": attr.label(allow_files=True, single_file=True, mandatory=True),
		"srcs": attr.label_list(allow_files=True),
		"dev_deps": attr.label_list(allow_files=True),
		"deps": attr.label_list(allow_files=True),
		"install_tool": attr.label(executable=True, allow_files=True,
			default=Label("//build_tools:npm_installer")),
		"pack_tool": attr.label(executable=True, allow_files=True,
			default=Label("//build_tools:npm_packer")),
	},
	outputs = {
		"tarball": "%{name}.tgz",
		"node_modules": "%{name}_node_modules.tar.gz"
	}
)

external_npm_module = rule(
	implementation = _external_npm_module,
	attrs = {
		"raw_target": attr.label(allow_files = True),
		"runtime_deps": attr.label_list(allow_files = True)
	},
)

