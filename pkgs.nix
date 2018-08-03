with rec {
  pkgs = import <nixpkgs> {};

  nix-helpers = pkgs.fetchgit {
    url    = http://chriswarbo.net/git/nix-helpers.git;
    rev    = "72d9d88";
    sha256 = "1kggqr07dz2widv895wp8g1x314lqg19p67nzr3b97pg97amhjsi";
  };

  warbo-packages = pkgs.fetchgit {
    url    = http://chriswarbo.net/git/warbo-packages.git;
    rev    = "fadf087";
    sha256 = "0z4jk3wk9lhlq3njr22wsr9plf5fw7mmpbky8l8ppn0gp698vq63";
  };

  repo = (import <nixpkgs> {
    overlays = [ (import "${nix-helpers}/overlay.nix" ) ];
  }).repo1803;
};
import repo {
  overlays = [ (import "${nix-helpers}/overlay.nix")
               (import "${warbo-packages}/overlay.nix") ];
}
