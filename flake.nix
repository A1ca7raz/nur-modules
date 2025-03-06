{
  description = "A1ca7raz's NUR for Modules";

  outputs = { self }:
    let
      lib = import ./lib.nix;
    in {
      nixosModules = lib.importModules ./modules;
    };
}
