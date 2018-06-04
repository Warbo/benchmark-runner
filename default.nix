{
  cacheDir    ? null,
  commitCount ? 10,  # Sane default prevents big repos going crazy
  repo        ? abort "No repo URL given"
}:

with builtins;
with rec {
  pkgs = import ./pkgs.nix;

  dir = pkgs.latestGit {
    url         = repo;
    deepClone   = true;  # Get all revisions, not just latest
    leaveDotGit = true;  # .git is deleted by default, for reproducibility
    stable      = { unsafeSkip = true; };  # Always get latest revision
  };

  run = with pkgs; runCommand "run-benchmarks-${sanitiseName repo}"
    {
      inherit dir cacheDir;
      commitCount = if isInt commitCount
                       then toString commitCount
                       else null;
      runner = import ./runner.nix pkgs;
    }
    ''
      mkdir "$out"
      cd "$out"
      "$runner"
    '';
};
with pkgs;
{
  results = runCommand "benchmark-results-${sanitiseName repo}"
    { inherit run; }
    ''ln -s "$run/results" "$out"'';

  html = runCommand "benchmark-pages-${sanitiseName repo}"
    { inherit run; }
    ''ln -s "$run/html"    "$out"'';
}
