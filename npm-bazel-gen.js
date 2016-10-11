"use strict";

var semver = require('semver');
var path = require('path');
var child_process = require('child_process');
var http = require('http');
var fs = require('fs');
var crypto = require('crypto');
var dns = require('dns');

// limit the number of sockets npm-bazel gen opens to try
// to help avoid overloading sinopia.
var agent = new http.Agent({maxSockets: 40});

var debugLogging = true;
mkdirp('tools/cache');
var packageHashFile = 'tools/cache/npm_package_hashes';
var registryCacheFile = 'tools/cache/npm_registry';

var packages = child_process.execFileSync('git', ['ls-files', '*/package.json'], {encoding: 'utf8'}).trim().split('\n');

var internalModules = {};
var externalDependencies = {};

var nameVersionPairs = {};
function NameVersionPair(name, version) {
	this.name = name;
	this.version = version;
	this.hashCode = name + "@" + version;
	nameVersionPairs[this.hashCode] = this;
}

var packageHashes = {};
const nbg_js = path.relative('.', __filename);

packages.forEach((packageFile) => {
	if (debugLogging) console.log(packageFile);
	var packageBody = fs.readFileSync(packageFile, 'utf8');
	var packageDir = path.dirname(packageFile);
	var packageDescriptor = JSON.parse(packageBody);
	internalModules[packageDescriptor.name] = packageDir;

	var deps = packageDescriptor.dependencies || {};
	Object.assign(deps, packageDescriptor.devDependencies || {});
	Object.keys(deps).forEach((name) => {
		var version = deps[name];
		var pair = new NameVersionPair(name, version);
		externalDependencies[pair.hashCode] = true;
	});
});

var registryCache = {};
var inFlight = {};
var fetchedAnything = false;
var crawled = {};

var workspaceUrls = {};
var versionCache = {};

var transitiveDependencyCache = {};

var npmIp = null;
var npmDnsInflight = [];

console.log("-- fetching from registry");

try {
	registryCache = JSON.parse(fs.readFileSync(registryCacheFile, 'utf8'));
} catch (e) {
	if (e.code !== "ENOENT") throw e;
}

inFlight.LOADING = () => {};
Object.keys(externalDependencies).forEach(function(dep) {
	var pair = nameVersionPairs[dep];
	if (internalModules[pair.name]) return;
	fetchFromRegistry(pair.name, () => crawlPackageJson(pair.name, pair.version));
});
delete inFlight.LOADING;
(() => {
	var inFlightCount = Object.keys(inFlight).length;
	if (debugLogging) console.log("in flight: " + inFlightCount);
	if (!inFlightCount) {
		doneCrawling();
	}
})();

function die(msg) {
	console.error(msg);
	process.exit(1);
}

function dnsLookup(callback) {
	if (npmIp) {
		return callback(npmIp);
	}
	npmDnsInflight.push(callback);
	if (npmDnsInflight.length > 1) {
		return;
	}
	dns.lookup('registry.npmjs.org', (err, result) => {
		if (err) {
			console.error(err);
			throw err;
		}
		console.log("dns success");
		npmIp = result;
		for (callback of npmDnsInflight) callback(npmIp);
	});
}

function fetchFromRegistry(name, callback) {
	if (inFlight[name]) {
		return inFlight[name].push(callback);
	}
	inFlight[name] = [callback];
	if (registryCache[name]) {
		return resolve();
	}
	console.log("  fetching " + name);
	dnsLookup((ip) => {
		var uripath = '/' + encodeURIComponent(name);
		http.request({agent: agent, host:ip, headers: {"Host":"registry.npmjs.org"}, path:uripath}, (res) => {
			if (res.statusCode != 200) die(`request for ${path} failed with status code ${res.statusCode}`);
			var body = "";
			res.on('data', function (chunk) {
				body += chunk;
			});

			res.on('end', function () {
				registryCache[name] = JSON.parse(body);
				console.log("  fetched " + name);
				fetchedAnything = true;
				resolve();
			});
		}).end();
	});

	function resolve() {
		var observers = inFlight[name];
		delete inFlight[name];
		if (observers) observers.forEach((callback) => callback());
	}
}

function getPackageJsonFromCache(name, version) {
	var response = registryCache[name];
	var resolvedVersion = semver.maxSatisfying(Object.keys(response.versions), version);
	return response.versions[resolvedVersion];
}

function crawlPackageJson(name, version) {
	var packageJson;
	if (isUrl(version)) {
		packageJson = {};
	} else {
		packageJson = getPackageJsonFromCache(name, version);
		if (!packageJson) {
			throw new Error(`should have been in cache: ${name}@${version}`);
		}
	}
	var code = packageJson.name + "@" + packageJson.version;
	if (!crawled[code]) {
		if (debugLogging) console.log("crawling " + code);
		crawled[code] = true;
		if (packageJson.dependencies) {
			inFlight[code + " LOADING"] = () => {};
			Object.keys(packageJson.dependencies).forEach((name) => {
				if (internalModules[name]) return;
				var version = packageJson.dependencies[name];
				fetchFromRegistry(name, () => crawlPackageJson(name, version));
			});
			delete inFlight[code + " LOADING"];
		}
	}
	var inFlightCount = Object.keys(inFlight).length;
	if (debugLogging) console.log("in flight: " + inFlightCount);
	if (!inFlightCount) {
		doneCrawling();
	}
}

function getResolvedVersion(name, version) {
	if (isUrl(version)) return version;
	var response = registryCache[name];
	if (!response) {
		throw new Error(`Missing response in registry cache: ${name}@${version}`);
	}
	var resolvedVersion = semver.maxSatisfying(Object.keys(response.versions), version);
	return resolvedVersion;
}

function writeFileOrDie(fileName, text) {
	try {
		fs.writeFileSync(fileName, text, 'utf8');
	} catch (e) {
		die("Couldn't write " + fileName + ": " + e);
	}
}

function doneCrawling() {
	if (fetchedAnything) {
		console.log("-- writing registry cache");
		writeFileOrDie(registryCacheFile, JSON.stringify(registryCache, null, 2));
	}
	console.log("-- writing thirdparty BUILD file");
	writeThirdPartyBuildFile();
	console.log("-- writing WORKSPACE");
	writeWorkspace();
	console.log("-- writing internal BUILD files");
	writeInternalBuildFiles();
	console.log("-- writing package hashes");
	writeFileOrDie(packageHashFile, JSON.stringify(packageHashes));
}

function writeThirdPartyBuildFile() {
	var resolvedExternalDependencies = {};
	Object.keys(externalDependencies).sort().forEach((code) => {
		var pair = nameVersionPairs[code];
		if (internalModules[pair.name]) return;
		var resolvedVersion = getResolvedVersion(pair.name, pair.version);
		var resolvedPair = new NameVersionPair(pair.name, resolvedVersion);
		resolvedExternalDependencies[resolvedPair.hashCode] = true;
		versionCache[pair.hashCode] = resolvedVersion;
	});

	var buffer = ["load('/tools/npm', 'external_npm_module')\n\n"];
	Object.keys(resolvedExternalDependencies).sort().forEach((code) => {
		var pair = nameVersionPairs[code];
		buffer.push(`external_npm_module(
	name='${pair.hashCode}',
	tarball='@${getRuleName(pair.name, pair.version)}//file',`);
		var transitiveDependencies = getTransitiveDependencies(pair.name, pair.version, 0);
		if (Object.keys(transitiveDependencies).length) {
			buffer.push("\n\truntime_deps=[\n\t\t");
			var first = true;
			Object.keys(transitiveDependencies).sort().forEach((depCode) => {
				var depPair = nameVersionPairs[depCode];
				if (first) {
					first = false;
				} else {
					buffer.push(",\n\t\t");
				}
				buffer.push(`'@${getRuleName(depPair.name, depPair.version)}//file'`);
			})
			buffer.push("\n\t],\n");
		}
		buffer.push("\n\tvisibility = ['//visibility:public'],\n)\n\n");
	});
	mkdirp('tools/npm-thirdparty');
	writeFileOrDie('tools/npm-thirdparty/BUILD', buffer.join(''));
}

function isUrl(version) {
	return /^https?:\/\//.test(version);
}

function getRuleName(name, version) {
	var rawKey;
	if (/^https?:\/\//.test(version)) {
		rawKey = name + "_tarball";
	} else {
		rawKey = name + "_" + version;
	}
	return rawKey.replace(/[^A-Za-z0-9_]+/g, "_").replace(/^_*/, '');
}

function addWorkspaceUrl(name, version) {
	var ruleName = getRuleName(name, version);
	if (isUrl(version)) {
		workspaceUrls[ruleName] = version;
	} else {
		var uripath = encodeURIComponent(name);
		var nameonly = name.replace(/^.*\//, '');
		workspaceUrls[ruleName] = `https://registry.npmjs.org/${uripath}/-/${nameonly}-${version}.tgz`;
	}
}

function getTransitiveDependencies(name, version, depth) {
	var pair = new NameVersionPair(name, version);
	if (transitiveDependencyCache[pair.hashCode]) {
		return transitiveDependencyCache[pair.hashCode];
	}
	if (debugLogging) console.log("  ".repeat(depth) + `${name}@${version}`);
	addWorkspaceUrl(name, version);
	var packageJson = getPackageJsonFromCache(name, version);
	var dependencies = {};
	if (packageJson && packageJson.dependencies) {
		dependencies = packageJson.dependencies;
	}
	var resultSet = {};
	transitiveDependencyCache[pair.hashCode] = resultSet;
	Object.keys(dependencies).forEach((childName) => {
		if (internalModules[childName]) return;
		var child = new NameVersionPair(childName, dependencies[childName]);
		try {
			var resolvedVersion = getResolvedVersion(childName, child.version);
		} catch (e) {
			console.error(`Error resolving dependency of ${name}@${version}`, e);
			throw e;
		}
		var resolvedChild = new NameVersionPair(childName, resolvedVersion);
		versionCache[child.hashCode] = resolvedVersion;
		addWorkspaceUrl(childName, resolvedVersion);
		resultSet[resolvedChild.hashCode] = true;
		var childResultSet = getTransitiveDependencies(childName, resolvedVersion, depth+1);
		Object.keys(childResultSet).forEach((key) => {
			resultSet[key] = true;
		});
	});
	return resultSet;
}

function writeWorkspace() {
	var buffer = [`
workspace(name='redfin_main')

load('/tools/node_repository_rules', 'node_binary', 'node_headers')
node_binary(
	version = '6.6.0',
	shas = {
		'linux': 'c22ab0dfa9d0b8d9de02ef7c0d860298a5d1bf6cae7413fb18b99e8a3d25648a',
		'darwin': 'c8d1fe38eb794ca46aacf6c8e90676eec7a8aeec83b4b09f57ce503509e7a19f',
	},
)

node_binary(
	version = '4.3.1',
	shas = {
		'linux': 'b3af1ed18a9150af42754e9a0385ecc4b4e9b493fcf32bf6ca0d7239d636254b',
		'darwin': '9c0751ee88a47c10269eb930d7ad7b103c2ba875c3a96204ca133dc52fc50826',
	},
)

# //tools/node_version_select is actually an alias that resolves to different
# node versions depending on whether or not '--define=node=6' is passed to bazel.
bind(
	name='node',
	actual='//tools:node_alias',
)

node_headers(
	version = '6.6.0',
	sha = '60b81c7276105a51e71ad8bc7f59163105e7c5dd1d992b173b5b66449b6df3fc'
)

node_headers(
	version = '4.3.1',
	sha = '8ba5c1e5eb5509e0f4f00d56e1916ac703fdd05cf353f119451f2b37c51987a5',
)

bind(
	name = 'node_headers',
	actual = '//tools:node_headers_alias',
)

`];
	Object.keys(workspaceUrls).sort().forEach((ruleName) => {
		var url = workspaceUrls[ruleName];
		buffer.push(`http_file(
	name='${ruleName}',
	url='${url}',
)
`);
	});
	writeFileOrSkip('WORKSPACE', buffer.join(''));
}

function mkdirp(dir) {
	try {
		fs.mkdirSync(dir);
	} catch (e) {
		if (e.code === "ENOENT") {
			mkdirp(path.dirname(dir));
			fs.mkdirSync(dir);
		} else if (e.code !== "EEXIST") {
			throw e;
		}
	}
}

function writeInternalBuildFiles() {
	packages.forEach((packageFile) => {
		var packageDir = path.dirname(packageFile);
		var currentName = path.basename(packageDir);
		var packageDescriptor = JSON.parse(fs.readFileSync(packageFile, 'utf8'));

		var output;

		var result = getBUILDFileContent(currentName, packageFile, packageDescriptor);
		var buffer = result.buffer;
		var loadCommands = result.loadCommands;
		output = loadCommands.join("\n") + "\n\n" + buffer.join("");

		var outFile = packageDir + "/BUILD"

		// XXX IMPORTANT: this call is actually async, so don't do anything
		// in this method after it.
		writeFileOrSkip(outFile, output);
	});
}

function writeFileOrSkip(filePath, output) {
	fs.readFile(filePath, 'utf8', (err, body) => {
		// Bazel invalidates some of its caches when timestamps change
		if (body === output) return;
		fs.writeFile(filePath, output, 'utf8', (err) => {
			if (err) die("Couldn't write " + filePath + ": " + err);
		});
	})
}

function getBUILDFileContent(currentName, packageFile, packageDescriptor) {
	var TAB = "\t";
	var NEWLINE = "\n";

	var loadCommands = ["load('/tools/npm', 'internal_npm_module')"];
	var buffer = [`
internal_npm_module(
	name='${currentName}',
	`
	];
	buffer.push("srcs=glob(['**'], exclude=['BUILD', 'node_modules/**']),\n");
	buffer.push("\tpackage_json='"+path.basename(packageFile)+"',\n");
	buffer.push("\tdeps=[\n")

	buffer = buffer.concat(getDependenciesArray(packageDescriptor.dependencies));

	buffer.push("\t],\n\tdev_deps = [\n")

	buffer = buffer.concat(getDependenciesArray(packageDescriptor.devDependencies));

	buffer.push("\t],\n");
	buffer.push("\tvisibility=['//visibility:public'],\n)\n");

	return { loadCommands, buffer };

}

function getDependenciesArray(depsObj) {
	var TAB = "\t";
	var NEWLINE = "\n";
	var buffer = [];
	if (depsObj) {
		Object.keys(depsObj || {}).sort().forEach((name) => {
			var version = depsObj[name];
			if (internalModules[name]) {
				buffer.push(`${TAB}${TAB}'//${internalModules[name]}',${NEWLINE}`);
			} else {
				var resolvedVersion = getResolvedVersion(name, version);
				buffer.push(`${TAB}${TAB}'//tools/npm-thirdparty:${name}@${resolvedVersion}',${NEWLINE}`);
			}
		});
	}
	return buffer;
}

function safeReadFileSync(filename) {
	try {
		return fs.readFileSync(filename, 'utf8');
	} catch (e) {
		if (e.code !== "ENOENT") throw e;
	}
}

