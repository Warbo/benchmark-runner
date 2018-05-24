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
    {
      inherit run;
      buildInputs = [ replace ];
      htmlInliner = import (fetchgit {
        url    = http://chriswarbo.net/git/html-inliner.git;
        rev    = "d24cca4";
        sha256 = "14y4w7l41j9sb7bfgjzidq89wgzhkwxvkgq5wb7qnqjfqcyygi63";
      });
      pre1  = "url: 'regressions.json',";
      post1 = ''
        url: 'regressions.json',
        beforeSend: function(xhr){
          if (xhr.overrideMimeType) {
            xhr.overrideMimeType("application/json");
          }
        },
      '';
      pre2  = ''dataType: "json",'';
      post2 = ''
        dataType: "json",
        beforeSend: function(xhr){
          if (xhr.overrideMimeType) {
            xhr.overrideMimeType("application/json");
          }
        },
      '';
    }
    ''
      cp -r "$run"/html ./result
      chmod +w -R       ./result

      echo "Fixing up HTML" 1>&2
      find "$PWD/result" -name "*.html" | while read -r F
      do
         CONTENT=$(cat "$F")
             DIR=$(dirname "$F")
        export BASE_URL="file://$DIR"
        echo "$CONTENT" | "$htmlInliner" > "$F"
      done

      echo "Fixing MIME types" 1>&2
      find ./result -name "*.js" | while read -r F
      do
        replace "$pre1" "$post1" -- "$F"
        replace "$pre2" "$post2" -- "$F"
      done

      mv ./result "$out"
      echo "Done" 1>&2
    '';
}
