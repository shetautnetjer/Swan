plugins {
    `kotlin-dsl`
}

gradlePlugin {
    plugins {
        register("jvmLibrary") {
            id = libs.plugins.demo.jvm.library.get().pluginId
            implementationClass = "JvmLibraryConventionPlugin"
        }
    }
}
