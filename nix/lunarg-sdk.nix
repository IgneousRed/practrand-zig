{ lib, stdenvNoCC, fetchurl, unzip }:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "lunarg-vulkan-sdk";
  version = "1.4.363.1";

  src = fetchurl {
    url = "https://sdk.lunarg.com/sdk/download/${finalAttrs.version}/mac/vulkan_sdk.zip";
    sha256 = "a65c707cf0a32bf8c2ca6b9af1985b7af61dbadfc19b352dae51a323f3a547a6";
  };

  nativeBuildInputs = [ unzip ];
  dontUnpack = true;
  dontFixup = true;
  installPhase = ''
    runHook preInstall
    # Qt's bundled metadata cache needs a writable home in the Nix sandbox.
    export HOME="$TMPDIR/installer-home"
    export CFFIXED_USER_HOME="$HOME"
    mkdir -p "$HOME"
    unzip -q "$src"
    installer="vulkansdk-macOS-${finalAttrs.version}.app/Contents/MacOS/vulkansdk-macOS-${finalAttrs.version}"
    # LunarG's copy-only mode installs core payloads without /usr/local writes
    # or administrator access. Do not run the optional system-wide installer.
    "$installer" --root "$out" --no-default-installations --accept-licenses --default-answer \
      --confirm-command install com.lunarg.vulkan.core copy_only=1
    test -x "$out/macOS/bin/glslc"
    test -x "$out/macOS/bin/spirv-val"
    test -f "$out/macOS/lib/libvulkan_kosmickrisp.dylib"
    test -f "$out/macOS/lib/libMoltenVK.dylib"
    runHook postInstall
  '';

  passthru = {
    sdkRoot = "${finalAttrs.finalPackage}/macOS";
    updateSource = {
      kind = "json-version";
      url = "https://vulkan.lunarg.com/sdk/latest/mac.json";
      path = [ "mac" ];
    };
  };
  meta = {
    description = "Exact LunarG SDK with MoltenVK and KosmicKrisp";
    homepage = "https://vulkan.lunarg.com/sdk/home/";
    platforms = [ "aarch64-darwin" ];
  };
})
