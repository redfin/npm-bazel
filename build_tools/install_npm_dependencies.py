#!/usr/bin/env python
import os, json, sys, re, shutil, tarfile, tempfile, contextlib, subprocess

@contextlib.contextmanager
def tempdir():
  dirpath = tempfile.mkdtemp()
  def cleanup():
    shutil.rmtree(dirpath)
  try:
    yield dirpath
  finally:
    cleanup()
    pass

package_file = sys.argv[1]
output_dir = sys.argv[2]
internal_modules_file = sys.argv[3]
version_cache_file = sys.argv[4]

def is_url(str):
	return str.startswith('http://') or str.startswith('https://')

def get_rule_name(name, version):
	raw_key = name + "_" + version;
	if is_url(version):
		raw_key = name + "_tarball"
	return re.sub(r'[^A-Za-z0-9_]+', "_", raw_key)

def recursive_symlink(source, target):
	source = os.path.abspath(source)
	target = os.path.abspath(target)
	target_dirname = os.path.dirname(target)
	if not os.path.exists(target_dirname):
		os.makedirs(target_dirname)
	subprocess.check_call(['rsync', '--archive', '--copy-unsafe-links', '--link-dest='+source, source+'/', target+'/'])

def get_external_dep_dir(name, version):
	rule_name = get_rule_name(name, version)
	external_dep_dir = 'external/' + rule_name
	sub_dirs = [f for f in os.listdir(external_dep_dir) if os.path.isdir(external_dep_dir+'/'+f)]
	if len(sub_dirs) != 1:
		raise Exception("There were {} subdirectories of external package dir {}".format(
			len(sub_dirs),
			os.path.abspath(external_dep_dir)
		))
	return (external_dep_dir, sub_dirs[0])


def symlink_shrinkwrap(directory, name, node):
	target = '{}/{}'.format(directory, name)
	if name in internal_modules:
		with tempdir() as tmp:
			target_dir = os.path.dirname(target)
			if not os.path.isdir(target_dir):
				os.makedirs(target_dir)
			with tarfile.open(internal_modules[name]["tarball"]) as tar: tar.extractall(tmp)
			os.system('mv ' + tmp + '/package ' + target)
	else:
		version = node["version"]
		external_dep_dir, external_dep_sub_dir = get_external_dep_dir(name, version)
		recursive_symlink('{}/{}'.format(external_dep_dir, external_dep_sub_dir), target)
	if "dependencies" in node:
		for dep_name, dep in node["dependencies"].viewitems():
			symlink_shrinkwrap('{}/{}/node_modules'.format(directory, name), dep_name, dep)

def get_path(node):
	if id(node) in parents:
		return get_path(parents[id(node)]) + '/' + names[id(node)]
	else:
		return "."

names = {}
parents = {}
def dedupe_tree(node, name):
	names[id(node)] = name
	#print("starting {} at {}".format(name, get_path(node)))
	if (id(node) in parents and id(parents[id(node)]) in parents):
		#print("raising '{}@{}'".format(name, node["version"]))
		parent = parents[id(node)]
		ancestor = parent
		while(id(ancestor) in parents):
			ancestor = parents[id(ancestor)]
			if name in ancestor["dependencies"]:
				if ancestor["dependencies"][name]["version"] == node["version"]:
					del parent["dependencies"][name]
					#print('{} provides {}@{}'.format(get_path(ancestor), name, ancestor["dependencies"][name]["version"]))
					#print('ended up at ' + get_path(ancestor["dependencies"][name]))
					return
				else:
					pass
					#print('{} provides {}@{}'.format(get_path(ancestor), name, ancestor["dependencies"][name]["version"]))
					#print('ended up at ' + get_path(node))
				break
			else:
				del parent["dependencies"][name]
				parent = ancestor
				parents[id(node)] = parent
				parent["dependencies"][name] = node
		#print('ended up at ' + get_path(node))
	if "dependencies" in node:
		for child_name in sorted(node["dependencies"].keys()):
			dependency = node["dependencies"][child_name]
			parents[id(dependency)] = node
			dedupe_tree(dependency, child_name)

version_cache = {}
with open(version_cache_file) as x: version_cache = json.load(x)

internal_modules = {}

with open(internal_modules_file) as x:
	internal_modules_json = json.load(x)
	for internal_package_file in internal_modules_json:
		with open(internal_package_file) as y:
			internal_package_json = json.load(y)
			internal_modules[internal_package_json["name"]] = {"package_file":internal_package_file, "tarball":internal_modules_json[internal_package_file]}

def add_dependencies(node, package, key, parents):
	#print("\t"  * len(parents) + key + ": " + node["name"]+"@"+node["version"])
	if key in package:
		for name in sorted(package[key]):
			version = package[key][name]
			code = name + '@' + version
			if code in version_cache:
				version = version_cache[code]
				code = name + '@' + version
			if code in parents:
				continue
			sub_parents = set(parents)
			sub_parents.add(code)
			if name in internal_modules:
				node["dependencies"][name] = build_supershrink(internal_modules[name]["package_file"], sub_parents)
			else:
				external_dep_dir, external_dep_sub_dir = get_external_dep_dir(name, version)
				node["dependencies"][name] = build_supershrink('{}/{}/package.json'.format(external_dep_dir, external_dep_sub_dir), sub_parents)
				node["dependencies"][name]["version"] = version

def build_supershrink(package_json, parents):
	with open(package_json) as x: package = json.load(x)
	node = {"name": package["name"], "version": package["version"], "dependencies": {}}
	add_dependencies(node, package, "dependencies", parents)
	if len(parents) == 0 and "devDependencies" in package:
		add_dependencies(node, package, "devDependencies", parents)
	return node

shutil.rmtree(output_dir + '/node_modules', ignore_errors=True)
os.makedirs(output_dir + '/node_modules')

supershrink = build_supershrink(package_file, set())

dedupe_tree(supershrink, "")

for name, shrinkwrap in supershrink["dependencies"].viewitems():
	symlink_shrinkwrap(output_dir + '/node_modules', name, shrinkwrap)