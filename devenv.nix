{ pkgs, ... }:

{
  android = {
    enable = true;
    platforms.version = [ "36" ];
    buildTools.version = [ "35.0.0" ];

    # The NDK is required: zig-src/build.zig links against its sysroot.
    ndk.enable = true;
    abis = [ "arm64-v8a" ];

    emulator.enable = false;
    systemImages.enable = false;
    googleTVAddOns.enable = false;
    sources.enable = false;
  };

  languages.zig = {
    enable = true;
    package = pkgs.zig_0_15;
  };

  # AGP 8.13 needs Gradle 8.13+; nixpkgs' `gradle_8` satisfies this and avoids
  # the wrapper's download of a dynamically linked toolchain.
  packages = [
    pkgs.gradle_8
    pkgs.android-tools
    pkgs.just
    pkgs.ktfmt
    pkgs.ktlint
  ];

  languages.java = {
    enable = true;
    jdk.package = pkgs.jdk21;
  };

  enterShell = ''
    # Ghostty's android-ndk package skips symlinked dirs under $ANDROID_HOME/ndk (which
    # is what the Nix SDK provides), so point it at the NDK directly.
    export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
    echo "chuchu dev shell: zig $(zig version), $(gradle --version | grep '^Gradle')"
    echo "Build APK: just apk"
  '';
}
