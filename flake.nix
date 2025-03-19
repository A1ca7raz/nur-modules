{
  description = "A1ca7raz's NUR for Modules";

  outputs = { self }:
    let
      lib = import ./lib.nix;

      modules = lib.importModules ./modules;
    in {
      nixosModules = modules // {
        all = { ... }: {
          imports = builtins.attrValues modules;
        };
      };
    };
}
