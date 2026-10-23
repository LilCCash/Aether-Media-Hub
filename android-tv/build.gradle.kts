// The Kotlin plugins are declared once here so every module shares one copy; the Android Gradle plugin is applied only by :app, which
// keeps the pure-Kotlin core buildable on a machine that cannot resolve it (-PcoreOnly=true).
plugins {
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}
