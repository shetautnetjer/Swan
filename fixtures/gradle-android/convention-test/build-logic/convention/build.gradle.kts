plugins {
    `kotlin-dsl`
}

gradlePlugin {
    plugins {
        register("androidTest") {
            id = libs.plugins.demo.android.test.get().pluginId
            implementationClass = "AndroidTestConventionPlugin"
        }
    }
}
