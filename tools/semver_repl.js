// this file runs semver so we can consume it from a Python process
try {
    semver = require(process.env["RUNFILES"]+"/node_6_6_0/lib/node_modules/npm/node_modules/semver/semver.js")
} catch (e) {
    semver = require(process.env["RUNFILES"]+"/node_4_3_1/lib/node_modules/npm/node_modules/semver/semver.js")
}

var readline = require('readline');
var rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

rl.on('line', function(line){
    console.log(eval(line));
})
