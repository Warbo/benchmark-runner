with rec {
  pkgs = import <nixpkgs> {};

  nix-helpers = pkgs.fetchgit {
    url    = http://chriswarbo.net/git/nix-helpers.git;
    rev    = "027e227";
    sha256 = "11niics6rq60zaicb6spkfpvp8nv3wszdfgpqnrml946p1bggy13";
  };

  warbo-packages = pkgs.fetchgit {
    url    = http://chriswarbo.net/git/warbo-packages.git;
    rev    = "c7f83b8";
    sha256 = "1cx2w518sxr4933dr548ichaljhcp0wvmbgyv3m56lmfk6fqdgzq";
  };

  repo = (import <nixpkgs> {
    overlays = [ (import "${nix-helpers}/overlay.nix" ) ];
  }).repo1803;
};
import repo { overlays = [
  (import "${  nix-helpers }/overlay.nix")
  (import "${warbo-packages}/overlay.nix")
]; }
