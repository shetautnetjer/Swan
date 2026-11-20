class JvmLibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) {
        with(target) {
            apply(plugin = "org.jetbrains.kotlin.jvm")
            // not apply(plugin = "com.android.library")
            if (pluginManager.hasPlugin("com.android.library")) {
                logger.warn("an Android module")
            }
        }
    }
}
