{ pkgs }:

{
  meshcmd = pkgs.callPackage ./meshcmd { };
  paia = pkgs.callPackage ./paia { };
}
