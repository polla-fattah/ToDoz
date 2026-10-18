#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
: "${ANDROID_SDK_ROOT:?Set ANDROID_SDK_ROOT to your Android SDK directory}"
BT="$ANDROID_SDK_ROOT/build-tools/35.0.0"
JAR="$ANDROID_SDK_ROOT/platforms/android-35/android.jar"
mkdir -p "$ROOT/build/classes" "$ROOT/build/dex"
"$BT/aapt" package -f -M "$ROOT/app/src/main/AndroidManifest.xml" -S "$ROOT/app/src/main/res" -A "$ROOT/app/src/main/assets" -I "$JAR" -F "$ROOT/build/resources.apk"
javac -source 8 -target 8 -bootclasspath "$JAR:$BT/core-lambda-stubs.jar" -d "$ROOT/build/classes" "$ROOT/app/src/main/java/com/taskflow/pro/MainActivity.java"
find "$ROOT/build/classes" -name '*.class' -print0 | xargs -0 "$BT/d8" --min-api 26 --lib "$JAR" --output "$ROOT/build/dex"
cp "$ROOT/build/resources.apk" "$ROOT/build/unsigned.apk"
(cd "$ROOT/build/dex" && zip -q "$ROOT/build/unsigned.apk" classes.dex)
"$BT/zipalign" -f 4 "$ROOT/build/unsigned.apk" "$ROOT/build/aligned.apk"
if [ ! -f "$ROOT/taskflow-signing.p12" ]; then
 keytool -genkeypair -keystore "$ROOT/taskflow-signing.p12" -storepass taskflow-local-build -keypass taskflow-local-build -alias taskflow -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=TaskFlow Personal Build'
fi
"$BT/apksigner" sign --ks "$ROOT/taskflow-signing.p12" --ks-pass pass:taskflow-local-build --out "$ROOT/TaskFlow.apk" "$ROOT/build/aligned.apk"
"$BT/apksigner" verify --verbose "$ROOT/TaskFlow.apk"
