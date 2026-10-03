# Run inside `devenv shell` (or via direnv); see devenv.nix.

# Native target triple for the JNI library; arm64 covers all current devices.
target := "aarch64-linux-android.24"
apk_dir := "android/app/build/outputs/apk"

default:
    @just --list

# Build libchuchu_jni.so into android/app/src/main/jniLibs/.
native:
    cd zig-src && zig build -Doptimize=ReleaseSmall -Dtarget={{ target }} jni

# Build the debug APK (arm64 only).
apk: native
    cd android && ANDROID_ABI_FILTERS=arm64-v8a gradle --console=plain assembleDebug
    @echo "{{ apk_dir }}/debug/app-debug.apk"

# Build the release APK. Needs android/app/key.jks plus KEYSTORE_PASSWORD, KEY_ALIAS and KEY_PASSWORD in the environment.
apk-release: native
    test -f android/app/key.jks || { echo "android/app/key.jks missing" >&2; exit 1; }
    cd android && ANDROID_ABI_FILTERS=arm64-v8a gradle --console=plain assembleRelease
    @echo "{{ apk_dir }}/release/app-release.apk"

# Install the debug APK on the connected device and launch it.
install: apk
    adb install -r {{ apk_dir }}/debug/app-debug.apk
    adb shell am start -n com.jossephus.chuchu/.MainActivity

fmt:
    ktfmt --kotlinlang-style $(find android/app/src -name '*.kt')

lint:
    ktlint --editorconfig=android/.editorconfig "android/app/src/**/*.kt" "android/**/*.gradle.kts"

clean:
    cd android && gradle --console=plain clean
    rm -rf zig-src/zig-out zig-src/.zig-cache android/app/src/main/jniLibs
