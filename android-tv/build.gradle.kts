// Each module applies its own plugins (see core/build.gradle.kts and app/build.gradle.kts): the pure-Kotlin core must be buildable
// on a machine that cannot resolve the Android Gradle plugin (-PcoreOnly=true), so the Android plugin cannot be declared here.
