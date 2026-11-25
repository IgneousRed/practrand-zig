{ pkgs }:
let
  pin = builtins.fromJSON (builtins.readFile ./practrand.json);
  archive = pkgs.fetchurl {
    inherit (pin) url;
    sha256 = pin.archiveSha256;
  };
in pkgs.runCommand "practrand-${pin.version}-source" {
  nativeBuildInputs = [ pkgs.unzip ];
  outputHashMode = "recursive";
  outputHash = pin.sourceHash;
  passthru = { inherit (pin) version; inherit archive; };
} ''
  mkdir unpacked "$out"
  unzip -q ${archive} -d unpacked
  entries=(unpacked/*)
  if [ "''${#entries[@]}" -eq 1 ] && [ -d "''${entries[0]}" ]; then
    cp -R "''${entries[0]}/." "$out/"
  else
    cp -R unpacked/. "$out/"
  fi
  # Git did not retain the archive's empty Visual C build-output directories.
  # Normalize only those empty directories; preserve every release file byte.
  find "$out" -depth -type d -empty -delete
''
