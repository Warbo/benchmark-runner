# Runs ASV in the given directory, caching results if requested.
{
  # Only used for derivation names
  name        ? "unnamed",

  # An optional string to a location where results will be copied from before
  # running, and into after running. Prevents re-benchmarking the same commits.
  cacheDir    ? null,

  # How many commits to benchmark. If we the repo has lots of commits, we might
  # not want to benchmark every single one. This limits us to the latest few. If
  # using a cacheDir, we may want to benchmark 'NEW' commits (i.e. everything
  # newer than the latest cached result); set this to 'null' to do that (but you
  # may want to pre-populate the cache first, if your repo has many commits!)
  commitCount ? 10,  # Sane default prevents big repos going crazy

  # The nixpkgs set to use, augmented with our helpers and packages (like asv)
  pkgs        ? import ./pkgs.nix,

  # URL of a git repo, if you want Nix to clone it for you. If you already have
  # a clone, you should leave this null and use 'dir' instead.
  repo        ? null,

  # Directory containing a git repo to benchmark. Defaults to cloning the 'repo'
  # argument, so you must provide a value for either 'repo' or 'dir' (if a 'dir'
  # is given then 'repo' will be ignored)
  dir         ? pkgs.latestGit {
    url         = if repo == null then abort "No repo URL given" else repo;
    deepClone   = true;  # Get all revisions, not just latest
    leaveDotGit = true;  # .git is deleted by default, for reproducibility
    stable      = { unsafeSkip = true; };  # Always get latest revision
  }
}:

with builtins;
with pkgs;
with {
  run = runCommand "run-benchmarks-${name}"
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
{
  results = runCommand "benchmark-results-${name}" { inherit run; } ''
    ln -s "$run/results" "$out"
  '';

  html = runCommand "benchmark-pages-${name}" { inherit run; } ''
    ln -s "$run/html"    "$out"
  '';
}
