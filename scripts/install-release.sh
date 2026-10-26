#!/usr/bin/env bash
# Build the release APK and install it on the connected phone in one step.
set -euo pipefail

cd "$(dirname "$0")/../app"

APK=build/app/outputs/flutter-apk/app-release.apk

# Gradle needs a JDK, not a JRE: a JRE-only package fails with "does not
# provide the required capabilities: [JAVA_COMPILER]".
jdk_with_javac () {
  local candidate
  for candidate in "${JAVA_HOME:-}" "$HOME"/.local/lib/jdk-21* /usr/lib/jvm/java-21-openjdk-amd64; do
    if [ -n "$candidate" ] && [ -x "$candidate/bin/javac" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

if ! JAVA_HOME=$(jdk_with_javac); then
  echo "No JDK with javac found — set JAVA_HOME to a JDK 21." >&2
  exit 1
fi
export JAVA_HOME

if ! command -v flutter >/dev/null; then
  echo "flutter is not on PATH." >&2
  exit 1
fi
if ! command -v adb >/dev/null; then
  echo "adb is not on PATH — add the Android SDK platform-tools to PATH." >&2
  exit 1
fi
if [ -z "$(adb devices | awk 'NR > 1 && $2 == "device"')" ]; then
  echo "No phone connected (or the screen is locked with USB debugging off)." >&2
  exit 1
fi

flutter build apk --release --target-platform android-arm64
adb install -r "$APK"

echo "Installed the $(du -h "$APK" | cut -f1) release build."
