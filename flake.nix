{
  description = "A1ca7raz's NUR for Modules";

  outputs = { ... }:
    let
      inherit (import ./lib.nix) imports;

      modules = imports ./modules;
    in {
      nixosModules = modules // {
        all = { ... }: {
          imports = builtins.attrValues modules;
        };
      };
    };
}
