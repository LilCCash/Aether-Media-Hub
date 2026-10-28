# media_kit / libmpv talk to the native player through JNI by name: shrinking must not rename or remove them.
-keep class com.alexmercerind.** { *; }
-keep class media.kit.** { *; }
-keepclassmembers class * { native <methods>; }
# screen_brightness, wakelock_plus and flutter_secure_storage are reached through their Flutter plugin registrants.
-keep class io.flutter.plugins.** { *; }
-dontwarn org.slf4j.**
