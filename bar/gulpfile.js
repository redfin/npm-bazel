var gulp = require("gulp");
var src = ["**/*.js", "!node_modules/**", "!target/**"];
gulp.task("compile", function() {
	gulp.src(src)
	// pointless example, but this could babelify or whatever
    .pipe(gulp.dest('target/'));
});
