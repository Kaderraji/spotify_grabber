# R8 rules for the release build. Flutter's own keeps are added by the Flutter
# Gradle plugin; this file only holds what the app itself needs.

# yt-dlp's Python bundle is unpacked with commons-compress on the first launch.
# Its ExtraFieldUtils registers each extra-field class by reflection and
# instantiates it with Class.newInstance(), which needs the public no-argument
# constructor. Nothing in reachable code calls those constructors directly, so
# R8 removes them and the registry throws "is not a concrete class" the first
# time a zip is opened: every fresh install died on startup for that reason.
-keep class org.apache.commons.compress.archivers.zip.** { *; }

# The library also reads its own class names and header ids reflectively.
-keepclassmembers class org.apache.commons.compress.archivers.zip.** {
    public <init>();
}
