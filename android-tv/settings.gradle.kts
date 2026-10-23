pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        if (providers.gradleProperty("coreOnly").orNull != "true") google()
        mavenCentral()
    }
}

rootProject.name = "aether-android-tv"

include(":core")
// The Android application needs the Android SDK. Pass -PcoreOnly=true to build and test only the pure-Kotlin core, which is what
// runs on a machine without the SDK.
val coreOnly = providers.gradleProperty("coreOnly").orNull == "true"
if (!coreOnly) include(":app")
