Build files only, for the Gradle task list `swan gradle-tasks` prints
(tests/lang_check.ts, `gradle`). Nothing here builds.

- kts-app: `plugins { id("com.android.application") }` and `include(":app")`.
- groovy-multi: Groovy, `apply plugin:`, a multi-line `include`, a nested
  module (`:core:data`) and a plain JVM module (`:lib`).
- catalog: `alias(libs.plugins....)` through gradle/libs.versions.toml, a root
  build file that only declares the plugins (`apply false`), and a
  com.android.test module beside the others.
- root-module: an Android app in the root project, no settings includes.
- raw-string: `"**/*.kt"` and a multi-line Kotlin raw string holding `**/*`
  above the plugins block, neither of which opens a comment. (Gradle wants
  plugins {} first; only the parse is checked here.)
- test-only: com.android.test modules only, so no unit-test compile.

Negative cases, which must keep the plain list:

- jvm-comment: a JVM module whose Android plugin ids are only in comments.
- root-withid: a root build file that only reacts to the plugin
  (`plugins.withId(...)`).
- root-withid-multiline: the same, with `withId(` and `withPlugin(` and the
  plugin id on the lines after.
- multiline-apply-false: plugin entries declared with `.apply(false)` on the
  lines after the `id(...)`.
- bad-include/repo: `include` names with ".." or "/", which would reach the
  Android build file in bad-include/outside; they are skipped.
- settings-comment: the only real include is the JVM `:lib`; `:old` (after
  `//` on the include line) and `:old2` (inside `/* */`) are Android modules
  that must not be followed.
