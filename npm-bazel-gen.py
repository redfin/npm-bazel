import json, subprocess, os, re, shutil, sys
from Queue import Queue
from threading import Thread

registry = "https://registry.npmjs.org/"

packages = subprocess.check_output(['git', 'ls-files', '*/package.json']).strip().split('\n')
#print '\n'.join(packages)

internal_modules = {}
external_dependencies = set()

print("-- scanning packages")
for package_file in packages:
	print(package_file)
	package_dir = os.path.dirname(package_file)
	with open(package_file) as x: package = json.load(x)
	internal_modules[package["name"]] = package_dir
	if "dependencies" in package:
		for name, version in package["dependencies"].viewitems():
			external_dependencies.add(name + "@" + version)
	if "devDependencies" in package:
		for name, version in package["devDependencies"].viewitems():
			external_dependencies.add(name + "@" + version)

version_cache = {}
dependency_cache = {}

if os.path.exists('build_tools/npm_version_cache'):
	with open('build_tools/npm_version_cache') as x: version_cache = json.load(x)
if os.path.exists('build_tools/npm_dependency_cache'):
	with open('build_tools/npm_dependency_cache') as x: dependency_cache = json.load(x)

workspace_urls = {}

def is_url(str):
	return str.startswith('http://') or str.startswith('https://')

def get_version(name, version):
	code = name + '@' + version
	if re.match(r'^[\d.]+\.[\d.]+\.[\d.]+$', version):
		#print("  -- version seems exact: " + code)
		return version
	elif is_url(version):
		#print("  -- version seems to be a url: " + code)
		return version
	elif code in version_cache:
		#print("  -- version cache hit: " + code + " = " + version_cache[code])
		return version_cache[code]
	print("  -- version: " + code)
	output = subprocess.check_output(['npm', '--registry', registry, 'view', code, 'version']).strip().split('\n')
	if len(output) > 1:
		last_line = output[-1]
		new_code = last_line.split(' ')[0]
		resolved_version = re.match(r'^(.+)@([^@]+)$', new_code).groups()[1]
	else:
		resolved_version = output[0]
	print("    -- recording {}@{} = {}".format(name, version, resolved_version))
	version_cache[code] = resolved_version
	with open('build_tools/npm_version_cache', 'w') as x: json.dump(version_cache, x, indent=2, separators=(',', ': '), sort_keys=True)
	return resolved_version

def get_dependencies(name, version):
	code = name + '@' + version
	if code in dependency_cache:
		return dependency_cache[code]
	print("  -- dependencies: " + code)
	result_string = subprocess.check_output(['npm', '--registry', registry, 'view', '--json', name+'@'+version, 'dependencies'])
	if not result_string:
		output = {}
	else:
		try:
			output = json.loads(result_string)
		except ValueError as e:
			raise Exception("error reading dependencies for {}@{}: <{}>\nCaused by: {}: {}".format(name, version, result_string, type(e).__name__, str(e))), None, sys.exc_info()[2]

	print("    -- " + json.dumps(output))
	dependency_cache[code] = output
	with open('build_tools/npm_dependency_cache', 'w') as x: json.dump(dependency_cache, x, indent=2, separators=(',', ': '), sort_keys=True)
	return output

def get_rule_name(name, version):
	raw_key = name + "_" + version;
	if is_url(version):
		raw_key = name + "_tarball"
	return re.sub(r'[^A-Za-z0-9_]+', "_", raw_key)

def add_workspace_url(name, version):
	rule_name = get_rule_name(name, version)
	if is_url(version):
		workspace_urls[rule_name] = version
	else:
		workspace_urls[rule_name] = '{repo_url}/{name}/-/{name}-{version}.tgz'.format(
			repo_url = registry,
			name = name,
			version = version
		)

def get_transitive_dependencies(parent_name, parent_version, dependencies):
	add_workspace_url(parent_name, parent_version)
	for name, version in get_dependencies(parent_name, parent_version).viewitems():
		resolved_version = get_version(name, version)
		add_workspace_url(name, resolved_version)
		code = name+'@'+resolved_version
		if code in dependencies:
			continue
		dependencies.add(code)
		get_transitive_dependencies(name, resolved_version, dependencies)

print('-- writing thirdparty BUILD file')

external_npm_module_template = """external_npm_module(
	name='{}@{}',
	raw_target='{}',{}
	visibility = ["//visibility:public"],
)
"""

def worker():
	while True:
		parent_name, parent_version, dependencies = q.get()
		resolved_parent_version = get_version(parent_name, parent_version)
		for name, version in get_dependencies(parent_name, resolved_parent_version).viewitems():
			resolved_version = get_version(name, version)
			code = name+'@'+resolved_version
			if code in dependencies:
				continue
			dependencies.add(code)
			q.put((name, resolved_version, dependencies))
		q.task_done()

q = Queue()

num_worker_threads = 16

for i in range(num_worker_threads):
	t = Thread(target=worker)
	t.daemon = True
	t.start()

resolved_external_dependencies = set()
for code in external_dependencies:
	name, version = re.match(r'^(.+)@([^@]+)$', code).groups()
	if name in internal_modules:
		continue
	if is_url(version):
		version = "tarball"
	resolved_version = get_version(name, version)
	resolved_external_dependencies.add(name+'@'+resolved_version)
	transitive_dependencies = set()
	q.put((name, version, transitive_dependencies))

q.join()
if not os.path.exists('build_tools/npm-thirdparty'):
	os.makedirs('build_tools/npm-thirdparty')

with open('build_tools/npm-thirdparty/BUILD', 'w') as BUILD:
	BUILD.write("load('/build_tools/npm', 'external_npm_module')\n\n");
	for code in sorted(resolved_external_dependencies):
		name, version = re.match(r'^(.+)@([^@]+)$', code).groups()
		print("-- " + code)
		transitive_dependencies = set()
		get_transitive_dependencies(name, version, transitive_dependencies)
		raw_target = "@{}//:raw".format(get_rule_name(name, version))
		depstring = ""
		if len(transitive_dependencies):
			deps = []
			for dep in sorted(transitive_dependencies):
				dep_name, dep_version = re.match(r'^(.+)@([^@]+)$', dep).groups()
				deps.append("'@{}//:raw'".format(get_rule_name(dep_name, dep_version)))
			depstring = "\n\truntime_deps=[\n\t\t" + ",\n\t\t".join(deps) + "\n\t],\n"
		BUILD.write(external_npm_module_template.format(
			name,
			version,
			raw_target,
			depstring
		))

print('-- writing workspace')

workspace_template = """new_http_archive(
	name='{rule_name}',
	url='{url}',
	build_file_content="filegroup(name='raw', srcs=glob(['*'], exclude_directories=0), visibility=['//visibility:public'])",
)
"""

if sys.platform == 'darwin':
	node_platform = 'darwin'
	phantom_platform = 'macosx'
	phantom_file_extension = 'zip'
else:
	node_platform = 'linux'
	phantom_platform = 'linux-x86_64'
	phantom_file_extension = 'tgz'

workspace_preamble = """
new_http_archive(
	name='node',
	url='https://nodejs.org/download/release/v4.3.1/node-v4.3.1-{node_platform}-x64.tar.gz',
	strip_prefix='node-v4.3.1-{node_platform}-x64',
	build_file_content="filegroup(name='raw', data=glob(['*'], exclude_directories = 0), visibility=['//visibility:public'])"
)

new_http_archive(
	name='phantomjs',
	url='http://thirdpartyrepository.redfintest.com/com/redfin/phantomjs/2.1.1/phantomjs-2.1.1-{phantom_platform}.{phantom_file_extension}',
	strip_prefix='phantomjs-2.1.1-{phantom_platform}',
	build_file_content="filegroup(name='executable', data=glob(['bin/phantomjs']), visibility=['//visibility:public'])"
)

new_http_archive(
	name='node_headers',
	url='https://nodejs.org/download/release/v4.3.1/node-v4.3.1-headers.tar.gz',
	build_file_content=r\"""
genrule(
	name='gyp-package',
	srcs=glob(['**']),
	outs=['gyp-package.tar.gz'],
	visibility=['//visibility:public'],
	cmd='''
rm -rf $(@D)/.node-gyp
mkdir -p $(@D)/.node-gyp
cp -r external/node_headers/node-v4.3.1 $(@D)/.node-gyp/4.3.1
echo 9 > $(@D)/.node-gyp/4.3.1/installVersion
tar zcf $@ -C $(@D) .node-gyp
'''
)
\"""
)


""".format(node_platform=node_platform, phantom_platform=phantom_platform, phantom_file_extension=phantom_file_extension)



with open('WORKSPACE', 'w') as WORKSPACE:
	WORKSPACE.write(workspace_preamble)
	for rule_name in sorted(workspace_urls.keys()):
		url = workspace_urls[rule_name]
		WORKSPACE.write(workspace_template.format(rule_name=rule_name, url=url))

print("-- writing internal BUILD files")
for package_file in packages:
	package_dir = os.path.dirname(package_file)
	with open(package_file) as x: package = json.load(x)
	dependencies = []
	if "dependencies" in package:
		for name in sorted(package["dependencies"].keys()):
			dependencies.append((name, package["dependencies"][name]))
	if "devDependencies" in package:
		for name in sorted(package["devDependencies"].keys()):
			dependencies.append((name, package["devDependencies"][name]))

	with open(package_dir+'/BUILD', 'w') as BUILD:
		BUILD.write("load('/build_tools/npm', 'internal_npm_module')\n\n");
		BUILD.write("internal_npm_module(\n    name='")
		currentName = os.path.basename(package_dir)
		BUILD.write(currentName)
		BUILD.write("',\n    srcs=glob(['**'], exclude=['node_modules/**', 'target/**'")
		# add custom exclusions here
		BUILD.write("]),\n    package_json='"+os.path.basename(package_file)+"',\n    ")
		# configure custom install/pack scripts here
		BUILD.write("deps=[\n")
		if "dependencies" in package:
			for name in sorted(package["dependencies"].keys()):
				version = package["dependencies"][name]
				if name in internal_modules:
					BUILD.write("        '//{}',\n".format(internal_modules[name]))
				else:
					resolved_version = get_version(name, version)
					BUILD.write("        '//build_tools/npm-thirdparty:{}@{}',\n".format(name, resolved_version))
		BUILD.write("    ],\n    dev_deps = [\n")
		if "devDependencies" in package:
			for name in sorted(package["devDependencies"].keys()):
				version = package["devDependencies"][name]
				if name in internal_modules:
					BUILD.write("        '//{}',\n".format(internal_modules[name]))
				else:
					resolved_version = get_version(name, version)
					BUILD.write("        '//build_tools/npm-thirdparty:{}@{}',\n".format(name, resolved_version))
		BUILD.write("    ],\n    visibility=['//visibility:public'],")
		BUILD.write("\n)\n")

		# add extra custom rules here
