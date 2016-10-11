#!/usr/bin/env python

import os, json, sys, re, shutil, tarfile, tempfile, contextlib
from subprocess import Popen, PIPE, check_call

package_file = sys.argv[1]
output_dir = sys.argv[2]
json_to_tarball_file = sys.argv[3]

GCP = os.environ.get('GCP', 'cp')
GTAR = os.environ.get('GTAR', 'tar')
SNZIP = os.environ.get('SNZIP', 'snzip')
RUNFILES = os.environ.get('RUNFILES')

debug_logging = False

def is_url(str):
    return str.startswith('http://') or str.startswith('https://')

def get_rule_name(name, version):
    raw_key = name + "_" + version;
    if is_url(version):
        raw_key = name + "_tarball"
    return re.sub(r'[^A-Za-z0-9_]+', "_", raw_key)

def populate_node_modules(directory, name, node, parent={}):
    '''Recursively populate a node_modules tree.
    '''
    # sometimes a package dependency is already present, eg. with bundled
    # dependencies. Just skip the dependency.
    do_install = True

    # e.g. node_modules/glob
    target = os.path.join(directory, name)
    if os.path.exists(target):
        do_install = False

    if do_install:
        if name in internal_modules:
            version = "INTERNAL"
        else:
            version = node["version"]
            if is_url(version):
                version = 'tarball'
        if not os.path.exists(directory): os.makedirs(directory)

        tzname = dependencies[name+"@"+version]['tarball']
        with open(tzname) as tz:
            unz = Popen([
                SNZIP if tzname.endswith('.sz') else 'gzip',
                '-dc',
            ], stdin=tz, stdout=PIPE)

        gtar = [
            GTAR,
            '-C', directory,
            '--warning=no-unknown-keyword',
            '--xform', 's,^package,{},'.format(name),
            '-x',
        ]
        check_call(gtar, stdin=unz.stdout)
        assert unz.wait() == 0

    if "dependencies" in node:
        for dep_name, dep in node["dependencies"].viewitems():
            populate_node_modules('{}/{}/node_modules'.format(directory, name), dep_name, dep, node)

def get_path(node):
    if id(node) in parents:
        return get_path(parents[id(node)]) + node['name'] + '/'
    else:
        return '/'

# a child node process runs node-semver for us
def version_satisfies(actual, version_range):
    child.stdin.write('semver.satisfies("{}", "{}")\n'.format(actual, version_range))
    child.stdin.flush()
    reply = child.stdout.readline()
    return "true\n" == reply

def max_satisfying(name, version_range):
    if (name, version_range) in version_cache:
        return version_cache[(name, version_range)]
    versions_json = json.dumps(list(known_versions[name]))
    if versions_json == '["INTERNAL"]' or versions_json == '["tarball"]':
        return version_range
    version_range_json = json.dumps(version_range)
    child.stdin.write('semver.maxSatisfying({}, {})\n'.format(versions_json, version_range_json))
    child.stdin.flush()
    reply = child.stdout.readline().rstrip()
    if not reply in known_versions[name]:
        child.kill()
        raise AssertionError("semver gave us an invalid version: {}, {} -> {}".format(
            versions_json, version_range_json, reply))
    version_cache[(name, version_range)] = reply
    return reply

parents = {}

version_cache = {}

dependencies = {}
known_versions = {}
internal_modules = set()

with open(json_to_tarball_file) as x:
    json_to_tarball = json.load(x)
    for sub_package_file in json_to_tarball:
        value = json_to_tarball[sub_package_file]
        with open(sub_package_file) as y:
            try:
                package_json = json.load(y)
            except ValueError as e:
                trace = sys.exc_info()[2]
                raise Exception("invalid json {}\nCaused by: {}: {}".format(sub_package_file, type(e).__name__, str(e))), None, sys.exc_info()[2]
            if value["internal"]:
                internal_modules.add(package_json["name"])
                version = "INTERNAL"
            elif os.path.dirname(os.path.dirname(sub_package_file)).endswith('_tarball'):
                version = "tarball"
            else:
                version = package_json["version"]
            if not package_json["name"] in known_versions:
                known_versions[package_json["name"]] = set()
            known_versions[package_json["name"]].add(version)
            dependencies[package_json["name"]+"@"+version] = {"package_file":sub_package_file, "tarball":value["tarball"]}

def find_insertion_point(name, version_range, node):
    # we want to insert the dependency at the highest level that does not already contain this dependency

    # for example, suppose we're installing "baz" which depends on "bar" which depends on "foo"
    # and we're deciding where to insert "foo@^1.0.0"
    #
    # if baz already depends on foo (bar is a sibling of foo):
    #   if bar's sibling foo matches ^1.0.0, then we should skip adding a duplicate foo; the existing foo is "satisfactory"
    #   otherwise (the parent's sibling doesn't match ^1.0.0 (say, 2.0.0) ) then we should add foo@1.0.0 as a dependency of bar
    # otherwise we check bar's parent (baz) for matching sibling dependencies, all the way up to the root
    # if the ancestors & siblings don't contain any "foo", then we should add "foo@1.0.0" to the root
    level = node["level"]+1
    old_path = get_path(node)
    parent = parents[id(node)] if id(node) in parents else None
    while parent:
        if name in parent["dependencies"]:
            if version_satisfies(parent["dependencies"][name]["version"], version_range):
                if debug_logging:
                    print("\t"  * level + name + "@" + version_range + " already exists as " +
                        parent["dependencies"][name]["version"] + " at " + get_path(node))
                return None
            else:
                break
        else:
            node = parent
            parent = parents[id(node)] if id(node) in parents else None
    if debug_logging:
        version = max_satisfying(name, version_range)
        print("\t{indent}{name}@{version_range} will be {version} at {new_path} from {old_path}".format(
            indent = "\t" * (node["level"]+2),
            name = name,
            version_range = version_range,
            version = version,
            new_path = get_path(node),
            old_path = old_path))
    return node

def add_dependencies(node, package, key):
    if key in package:
        todo = []
        for name in sorted(package[key]):
            version_range = package[key][name]
            insertion_point = find_insertion_point(name, version_range, node)
            if not insertion_point:
                continue

            version = max_satisfying(name, version_range)

            sub_node = {"name": name, "version": version, "dependencies": {}, "level": insertion_point['level']+1}
            parents[id(sub_node)] = insertion_point
            insertion_point["dependencies"][name] = sub_node

            bundle_deps = package.get('bundleDependencies') or package.get('bundledDependencies')
            if bundle_deps:
                sub_node['bundle_deps'] = bundle_deps

            todo.append(sub_node)

        for node in todo:
            name = node['name']

            if name in internal_modules:
                version = "INTERNAL"
            else:
                version = node['version']
                if is_url(version):
                    version = 'tarball'

            package_file = dependencies[name+"@"+version]["package_file"]
            with open(package_file) as x: package = json.load(x)
            add_dependencies(node, package, "dependencies")

shutil.rmtree(output_dir + '/node_modules', ignore_errors=True)
os.makedirs(output_dir + '/node_modules')

child = Popen(['node', RUNFILES + '/redfin_main/tools/semver_repl.js'], stdin=PIPE, stdout=PIPE, bufsize=1)

with open(package_file) as x: package = json.load(x)
name = package.get('name') or package['bazel_name']
root = {"name": name, "version": package["version"], "dependencies": {}, "level": 0}

add_dependencies(root, package, "dependencies")
add_dependencies(root, package, "devDependencies")

child.kill()

for name, shrinkwrap in root["dependencies"].viewitems():
    populate_node_modules(output_dir + '/node_modules', name, shrinkwrap)
