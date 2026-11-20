plugins {
    `kotlin-dsl`
}

gradlePlugin {
    plugins {
        register("androidFeature") {
            id = "demo.android.feature"
            implementationClass = "demo.conventions.AndroidFeatureConventionPlugin"
        }
        register("androidLibrary") {
            id = libs.plugins.demo.android.library.get().pluginId
            implementationClass = "AndroidLibraryConventionPlugin"
        }
    }
}
