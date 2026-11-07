# media_kit / libmpv talk to the native player through JNI by name: shrinking must not rename or remove them.
-keep class com.alexmercerind.** { *; }
-keep class media.kit.** { *; }
-keepclassmembers class * { native <methods>; }
# screen_brightness, wakelock_plus and flutter_secure_storage are reached through their Flutter plugin registrants.
-keep class io.flutter.plugins.** { *; }
-dontwarn org.slf4j.**
# flutter_local_notifications serialises its schedules with Gson through reflection.
-keep class com.dexterous.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
# Cast, Play Core deferred components and Kotlin metadata are looked up by name.
-keep class com.google.android.gms.cast.** { *; }
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
