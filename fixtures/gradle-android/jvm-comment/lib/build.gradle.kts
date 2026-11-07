/* plugins { id("com.android.application") } */
/*
 * Was an Android library once:
 *     id("com.android.library")
 */
plugins {
    kotlin("jvm") // not id("com.android.library")
}
val note = "/* not a comment */"
