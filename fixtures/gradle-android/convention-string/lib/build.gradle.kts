plugins {
    kotlin("jvm")
}

// The repo's Android convention plugin named in a string, not applied.
val conventionName = "demo.android.library"
tasks.register("which") { description = conventionName }
