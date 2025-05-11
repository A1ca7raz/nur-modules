let
  inherit (builtins)
    length
    split
    attrNames
    elemAt
    filter
    readDir
    foldl'
    pathExists
  ;
in rec {
  is = regex: str: length (split regex str) != 1;

  mapAttrs' = f: set: foldl'
    (acc: f': acc // f f' set.${f'})
    {}
    (attrNames set);

  isNix = is "\\.nix$";

  removeExt = x: elemAt (split "\\.[a-zA-Z0-9]+$" x) 0;

  isVisible = x: ! is "^_" (baseNameOf x);

  getDirItemList = dir: type:
    let
      items = readDir dir;
    in
      filter (i: items.${i} == type) (attrNames items);

  imports = path:
    let
      dir = readDir path;
    in foldl'
      (acc: n:
        if dir."${n}" == "directory" && pathExists /${path}/${n}/default.nix
        then acc // { ${n} = import /${path}/${n}; }
        else acc
      )
      {}
      (attrNames dir);
}
