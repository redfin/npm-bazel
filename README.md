This project provides a generator tool, `npm-bazel-gen.py`, to generate `WORKSPACE` rules and `BUILD` files for [npm](https://www.npmjs.com/) modules. It also provides Skylark rules in `build_tools/npm.bzl` to build `npm` modules in Bazel's sandbox.

# Stability: prototype

This is a public clone of code that we're using internally at [Redfin](https://www.redfin.com/). The version we actually use seems to be working, but we cannot guarantee that this repository will be stable/maintained. (But hope springs eternal, and if people seem to like it, we could stabilize it further.)

# Getting Started

Generate the `WORKSPACE` and `BUILD` files using the Python script, then build the example projects.

```
python npm-bazel-gen.py
bazel build foo
```

# Background

## Required knowledge

* What `npm install` kinda does, a little about how node_modules work
* What a Bazel Skylark rule does http://bazel.io/docs/skylark/index.html
    * This is a bit tougher to come by, but you can get pretty far by reading these three docs in order:
        * http://bazel.io/docs/skylark/concepts.html
        * http://bazel.io/docs/skylark/rules.html
        * http://bazel.io/docs/skylark/cookbook.html
        * And then read them again, starting with "concepts"

## What does `npm install` do?

`npm install` with no arguments does two-and-a-half things.

1. "Install dependencies"
    1. "Download" dependencies declared in `package.json` into `./node_modules` (de-duping dependencies and resolving circular dependencies as needed)
    2. "Rebuild" those downloaded dependencies. (You can `npm rebuild` to re-run this.)
        * Compile native code: if any of those deps had native code in them, they need to be recompiled. There are no limitations on what this build step is allowed to do.
        * Symlink scripts: if any of the deps provided executable scripts to run in the "bin" section of package.json, ("gulp" is especially important,) then node will symlink them into `node_modules/.bin`

        For example, `node_modules/.bin/gulp` will be a symlink to `node_modules/gulp/bin/gulp.js`
2. "Prepublish" current project: if `package.json` declares a `scripts.prepublish` step, it'll run that. A common scripts.prepublish step is: "gulp prepublish". (npm automatically adds `node_modules/.bin` to the path when running this script.)

To generate a `.tgz` output file, we can run `npm pack`, which does two things:

<ol start="3">
<li>Prepublish: runs (re-runs) the "prepublish" step</li>
<li>Tar: It tars up everything in the current directory, except for anything explicitly ignored by `.npmignore`.</li>
</ol>


Some of these steps violate Bazel's sandbox.

* 1a "Download": Obviously, this uses the network.
* 1b "Rebuild": The rebuild scripts are, in principle, allowed to do anything, including access the network, and sometimes they do that. In particular, the way to generate bindings from node to native code is to run `node-gyp`, which tries to download header files on first launch and caches them in `~/.node-gyp`.
* 2 "Prepublish": This script may try to access the network. For example, lots of modules use [`nsp`](https://www.npmjs.com/package/nsp) to query for known Node security vulnerabilities. (`nsp` has an offline mode, but it's "unofficial, unsupported.")

## How we implemented that in Bazel

1. Install phase:
    1. Download:
        * `npm-bazel-gen.js` scans all package.json files, finding the full dependency tree (tree of trees? forest?) and declares all external dependencies as rules in the `WORKSPACE` file
        * `tools/install-npm-dependencies.py` is a script that simulates what `npm install` would have done, including de-duping dependencies and handling circular dependencies. (`npm` allows circular dependencies! 😮) **BEWARE This script is currently imperfect! It doesn't do exactly what `npm` would have done.**
    2. Rebuild:
        * `tools/npm_installer.sh` is a script that runs `npm rebuild` directly after `install_npm_dependencies`.
        * To avoid sandbox violations, we set `HOME` to a temp directory and pre-install `/.node-gyp` in there
    3. We do _not_ run prepublish during this "install" phase, because we plan to run it during packaging.
    4. We then tar up the generated `node_modules` folder. (We prefer `snzip` over `gzip` for performance reasons.)
2. Pack phase: `tools/npm_packer.sh`
    1. Setup: We're not allowed to modify source files directly, so we setup by:
        * rsyncing source files to a work directory
        * untar the generated `node_modules` folder into the work directory
    2. Pack: We run the prepublish script, if any, and tar up the final output. (Again, we prefer `snzip` over `gzip`.)

## `npm.bzl`

`npm.bzl`  defines two rules, `external_npm_module` and `internal_npm_module`. "external" means "third party," as opposed to "internal" modules being built by Bazel.

The `internal_npm_module` rule is responsible for running `npm_installer.sh` and then `npm_packer.sh` as `ctx.action`s.

The majority of `npm.bzl` is a bunch of code to marshall the correct list of inputs and outputs for the "install" phase and then the "pack" phase. Both types of rules return a `struct()` containing four fields:

* `internal` (boolean): `external_npm_module` sets this to false, internal_npm_module sets this to true
* `transitive_external_deps` (list<module>): the full set of external dependency modules for the current module (including indirect dependencies)
* `transitive_internal_deps` (list<module>): the full set of internal dependency modules for the current module (including indirect dependencies). `external_npm_module` returns an empty list for this.
* `json_to_tarball_map` (dict): a mapping from `package.json` file paths to their corresponding tarballs; we'll use this in `install_npm_dependencies.py`

In addition, internal modules return these two fields:

* `tarball` (file): The generated tarball file for this module
* `node_modules` (file): A generated tarball file containing this module's own `node_modules` folder
* `package_json` (file): The `package.json` file input (used by other rules to compute the dependency tree)

Skylark calls this system of a rule returning a `struct()` a "provider" in Skylark. http://bazel.io/docs/skylark/rules.html (Cmd-F for the "Providers" section)

Skylark's documentation on providers is pretty light, but all it means is: rules can return a `struct()` of data to _provide_ it to dependent rules.

The top of `npm.bzl` is taking the list of `deps` and the list of `dev_deps` and creates a `json_to_tarball_map` of the required dependencies. We then write that map to disk (as JSON), so `install_npm_dependencies.py` knows where to look for dependencies.

The `internal_npm_module` rule then runs two `ctx.action` commands:

1. the "install" phase, which runs `tools/npm_installer.sh` to generate `foo_node_modules.tar.sz` with these inputs:
    1. All dependencies
    2. `package.json` file for the current module
    3. `json_to_tarball_map` file as JSON
2. the "pack" phase, which runs `tools/npm_packer.sh` to generate `foo.tgz` with these inputs:
    1. foo_node_modules.tar.gz
    2. All of the source files in the current working directory


## Non-standard projects

In our project at Redfin, we have a bunch of projects that do weird/non-standard stuff, usually during the "pack" phase, but sometimes during the "install" phase.

The `internal_npm_module` rule has `install_tool` and `pack_tool` attributes, which default to `tools:npm_installer` and `tools:npm_packer` but you can override them to anything you want, including defining a `sh_binary` with arbitrary dependencies. (You have to hack in special cases to `npm-bazel-gen.py` to make it add those for you, when you want it.)

In addition, the default packer tool looks for a `./extra-bazel-script` file in the current directory, and if it finds one, it just runs whatever it sees there. In some cases, that's enough pluggability.

## Open questions

Bazel users are looking for a basic (but fast) set of loadable repository rules (`node_binary`, `node_library`, `node_test`) that just DTRT. Is that even possible?

I'm unclear even for myself whether we're providing `npm` support or `node` support for Bazel. For comparison, Bazel clearly provides `java` support, but its `maven` support is not as solid. (Simulating what Maven does is kinda complicated and may be undesirable.) Should we even try to provide `npm` support, as opposed to `node` support?

IMO, it's still a bit of an unsolved problem in `node` land how best to have a library X that depends on a library Y that depends on a library Z all in a monolithic repo. Are we solving that problem, with the added restriction that we're doing it in Bazel?

More broadly, can this code be made simpler without sacrificing performance? (A lot of the weird complexities that have crept in are due to perf/reliability enhancements.)