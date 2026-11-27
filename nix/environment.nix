{ pkgs, nixpkgsRev, withVulkan ? false }:
let
  inherit (pkgs) lib;
  zig = pkgs.zig_0_17;
  darwin = pkgs.stdenv.hostPlatform.isDarwin;
  toolchain = if darwin then import ./llvm23/llvm23-toolchain.nix { inherit pkgs; } else null;
  python = if darwin then toolchain.python else pkgs.python315;
  git = if darwin then toolchain.git else pkgs.git;
  curl = if darwin then toolchain.dependencies.curl else pkgs.curl;
  bash = if darwin then pkgs.bash.override {
    readline = toolchain.dependencies.readline;
  } else pkgs.bash;
  native = if darwin then toolchain.llvmPackages else pkgs.llvmPackages_23;
  appleSdk = if darwin then toolchain.sdk else null;
  vulkan = if darwin then pkgs.callPackage ./lunarg-sdk.nix { } else
    pkgs.symlinkJoin {
      name = "practrand-vulkan-sdk";
      version = pkgs.vulkan-headers.version;
      paths = [ pkgs.vulkan-headers pkgs.vulkan-loader pkgs.vulkan-loader.dev pkgs.shaderc pkgs.spirv-tools ];
    };
  vulkanRoot = if darwin then vulkan.sdkRoot else "${vulkan}";
  tools = [
    # The compiler wrapper already exposes its matching binutils.
    zig python native.clang
    bash pkgs.coreutils git curl
  ] ++ lib.optional darwin native.llvm;
  platformInputs = lib.optional darwin appleSdk;
  variables = {
    PRACTRAND_ZIG_VERSION = zig.version;
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    CURL_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  } // lib.optionalAttrs darwin {
    DEVELOPER_DIR = "${appleSdk}";
    SDKROOT = appleSdk.sdkroot;
    PRACTRAND_SYSTEM_CXX_LIB = "${native.clang.libcxx}/lib";
  } // lib.optionalAttrs withVulkan {
    VULKAN_SDK = vulkanRoot;
  } // lib.optionalAttrs (darwin && withVulkan) {
    DYLD_LIBRARY_PATH = "${vulkanRoot}/lib";
    VK_DRIVER_FILES = "${vulkanRoot}/share/vulkan/icd.d/libkosmickrisp_icd.json:${vulkanRoot}/share/vulkan/icd.d/MoltenVK_icd.json";
    VK_LAYER_PATH = "${vulkanRoot}/share/vulkan/explicit_layer.d";
  };
  environmentMetadata = pkgs.writeTextDir "share/project-environment.json" (builtins.toJSON {
    schema = 1;
    inherit variables;
    unset = lib.optionals (!withVulkan) [ "VULKAN_SDK" "VK_DRIVER_FILES" "VK_LAYER_PATH" ]
      ++ lib.optionals darwin [ "VK_ICD_FILENAMES" "DYLD_FALLBACK_LIBRARY_PATH" ]
      ++ lib.optionals (darwin && !withVulkan) [ "DYLD_LIBRARY_PATH" ];
  });
  dependencies = [{
    name = "nixpkgs";
    current = nixpkgsRev;
    kind = "github-revision";
    repository = "NixOS/nixpkgs";
    ref = "nixpkgs-unstable";
  } {
    name = "llvm";
    current = "llvmorg-${native.clang.version}";
    kind = "github-release";
    repository = "llvm/llvm-project";
  }] ++ lib.optional darwin (vulkan.updateSource // {
    name = "vulkan-sdk";
    current = vulkan.version;
  });
  updateMetadata = pkgs.writeTextDir "share/dependency-updates.json" (builtins.toJSON {
    schema = 1;
    inherit dependencies;
  });
in
assert lib.assertMsg (zig.version == "0.17.1") "practrand-zig requires its approved Zig 0.17.1 lock";
{
  # The closure owns tools only; callers keep source, fixtures and writable state.
  package = pkgs.buildEnv {
    name = "practrand-zig-dev-environment";
    paths = tools ++ platformInputs ++ lib.optional withVulkan vulkanRoot
      ++ [ environmentMetadata updateMetadata ];
  };
  shell = pkgs.mkShellNoCC (variables // {
    packages = tools;
    buildInputs = platformInputs ++ lib.optional withVulkan vulkanRoot;
  });
  versions = {
    zig = zig.version;
    python = python.version;
    clang = native.clang.version;
    binutils = native.clang.bintools.version;
  } // lib.optionalAttrs withVulkan { vulkan-sdk = vulkan.version; }
    // lib.optionalAttrs darwin {
    apple-sdk = appleSdk.version;
  };
  inherit dependencies variables python;
  vulkanSdk = vulkan;
}
