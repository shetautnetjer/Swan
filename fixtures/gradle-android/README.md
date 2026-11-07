Build files only, for the Gradle task list `swan gradle-tasks` prints
(tests/lang_check.ts, `gradle`). Nothing here builds.

- kts-app: `plugins { id("com.android.application") }` and `include(":app")`.
- groovy-multi: Groovy, `apply plugin:`, a multi-line `include`, a nested
  module (`:core:data`) and a plain JVM module (`:lib`).
- catalog: `alias(libs.plugins....)` through gradle/libs.versions.toml, a root
  build file that only declares the plugins (`apply false`), and a
  com.android.test module beside the others.
- root-module: an Android app in the root project, no settings includes.
- test-only: com.android.test modules only, so no unit-test compile.
