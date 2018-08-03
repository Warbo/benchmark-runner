pkgs:
with builtins;
with pkgs;
with rec {
  go = wrap {
    name  = "benchmark-runner";
    paths = [ (python.withPackages (p: [ asv-nix ])) bash fail jq ] ++
            (withNix {}).buildInputs;
    vars  = withNix {
      inherit htmlFixer;
      inherit (import ./cache.nix pkgs) cacheResults setupCache;
      asvNix         = asv-nix;
      GIT_SSL_CAINFO = "${cacert}/etc/ssl/certs/ca-bundle.crt";
      runner         = pkgs.writeScript "benchmark-runner.sh" ''
        #!/usr/bin/env bash
        set -e

        # Real values taken from a Thinkpad X60s
        echo "Generating machine config" 1>&2
        asv machine                                                   \
          --arch    "i686"                                            \
          --cpu     "Genuine Intel(R) CPU          L2400  @ 1.66GHz"  \
          --machine "dummy"                                           \
          --os      "Linux 4.4.52"                                    \
          --ram     "3093764"

        # We run benchmarks from a function, so we can retry in some failure
        # cases
        function runBenchmarks {
          echo "Running asv on range $1" 1>&2
          TOO_FEW_MSG="unknown revision or path not in the working tree"
          if O=$(asv run --show-stderr --machine dummy "$1" 2>&1 |
                 tee >(cat 1>&2))
          then
            # Despite asv exiting successfully, we might have still hit a git
            # rev-parse failure
            echo "$O" | grep 'asv.util.ProcessError:' > /dev/null || return 0
            echo "Spotted ProcessError from asv run, investigating..." 1>&2

            echo "$O" | grep "$TOO_FEW_MSG" > /dev/null ||
              fail "Don't know how to handle this error, aborting"
            echo "Looks like we asked for too many commits, going to retry" 1>&2
          fi

          # Handle failures based on their error messages: some are benign
          if echo "$O" | grep 'No commit hashes selected' > /dev/null
          then
            # This happens when everything's already in the cache
            echo "No commits needed benchmarking, so asv run bailed out" 1>&2
          fi
          if echo "$O" | grep "$TOO_FEW_MSG" > /dev/null
          then
            echo "Asked to benchmark '$commitCount' commits, but there"    1>&2
            echo "aren't that many on the branch. Retrying without limit." 1>&2
            runBenchmarks "HEAD" || fail "Retry attempt failed"
            return 0
          fi

          fail "asv run failed, and it wasn't for lack of commits"
        }

        # Default to everything since last run (which is all, for uncached);
        # override by giving a commitCount.
        RANGE="NEW"
        if [[ -n "$commitCount" ]]
        then
          # Include HEAD and ancestors, exclude 'commitCount'th ancestor and its
          # ancestors.
          # NOTE: This will die if there are fewer than commitCount ancestors,
          # which we handle in the runBenchmarks function.
          # NOTE: We only talk about commits (HEAD and ancestors), rather than
          # branches, since nixpkgs's fetchgit function messes with .git, which
          # can delete branch information (specifically, the branch head refs)
          RANGE="HEAD~$commitCount..HEAD"
        fi
        runBenchmarks "$RANGE" || fail "Failed to run benchmarks"

        echo "Starting asv publish" 1>&2
        asv publish
      '';
    };
    script = ''
      #!/usr/bin/env bash
      set   -e
      shopt -s nullglob

      [[ -n "$dir" ]] || fail "No 'dir' given"

      GOT=0
      while read -r F; do GOT=1; done < <(find "$dir" -name 'asv.conf.json')
      [[ "$GOT" -eq 1 ]] || fail "No asv.conf.json found"
      unset GOT

      TEMPDIR=$(mktemp -d --tmpdir "benchmark-runner-temp-XXXXX")
      function cleanUp {
        rm -rf "$TEMPDIR"
      }
      trap cleanUp EXIT
      pushd "$TEMPDIR"

        export HOME="$PWD/home"
        mkdir "$HOME"

        echo "Making mutable copy of '$dir' to benchmark" 1>&2
        cp -r "$dir" ./src
        chmod +w -R  ./src

        pushd ./src
          while read -r F
          do
            pushd "$(dirname "$F")"
              echo "Reading config" 1>&2
              CONFIG=$(grep -v '^ *//' < "$F")

              RESULTS=$(echo "$CONFIG" | jq -r '.results_dir') ||
              RESULTS="$PWD/.asv/results"
              RESULTS=$(readlink -f "$RESULTS")

              HTML=$(echo "$CONFIG" | jq -r    '.html_dir') ||
              HTML="$PWD/.asv/html"
              HTML=$(readlink -f "$HTML")

              export RESULTS
              export HTML

              DIR="/nowhere"
              [[ -z "$cacheDir" ]] || DIR=$(echo "$CONFIG" | "$setupCache")

              if [[ -e shell.nix ]] || [[ -e default.nix ]]
              then
                echo "Running asv in nix-shell" 1>&2
                nix-shell --show-trace --run "$runner"
              else
                echo "No nix-shell file found, running asv 'bare'" 1>&2
                "$runner"
              fi

              [[ -e "$RESULTS" ]] || fail "No results ($RESULTS) found"
              [[ -e "$HTML"    ]] || fail "No HTML ($HTML) found"

              "$htmlFixer" "$HTML"

              export DIR
              [[ -z "$cacheDir" ]] || "$cacheResults"
            popd
            break
          done < <(find . -name 'asv.conf.json')
        popd
      popd
      mv "$RESULTS" ./results
      mv "$HTML"    ./html
    '';
  };

  htmlFixer = wrap {
    name  = "htmlFixer";
    paths = [ bash fail replace ];
    vars  = {
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
    };
    script = ''
      #!/usr/bin/env bash
      set -e

      [[ -n "$1" ]] || fail "No HTML dir given"

      echo "Fixing up HTML" 1>&2
      find "$1" -name "*.html" | while read -r F
      do
         CONTENT=$(cat     "$F")
             DIR=$(dirname "$F")
        export BASE_URL="file://$DIR"
        echo "$CONTENT" | "$htmlInliner" > "$F"
      done

      echo "Fixing MIME types" 1>&2
      find "$1" -name "*.js" | while read -r F
      do
        replace "$pre1" "$post1" -- "$F"
        replace "$pre2" "$post2" -- "$F"
      done

      echo "Done" 1>&2
    '';
  };

  test = runCommand "benchmark-runner-test"
    {
      inherit go;
      buildInputs = [ fail git jq ];
      project     = attrsToDirs {
        "asv.conf.json" = writeScript "example-asv.conf.json" (toJSON {
          benchmark_dir = "b"; branches = [ "master" ]; builders = {};
          dvcs = "git"; env_dir = "e"; environment_type = "nix"; html_dir = "h";
          installer = "x: import (x.root + \"/x.nix\")"; matrix = {};
          plugins = [ "asv_nix" ]; project = "test"; repo = ".";
          results_dir = "r"; version = 1;
        });
        b = { "__init__.py" = writeScript "empty" "";
              "x.py" = writeScript "x.py" ''def track_x(): return 42''; };
        "x.nix" = writeScript "dummy" ''
          (import <nixpkgs> {}).runCommand "env" {} ${"''"}
            mkdir -p "$out/bin"
            ln -s "${python}/bin/python" "$out/bin/python"
          ${"''"}
        '';
      };
    }
    ''
      shopt -s nullglob

      export HOME="$PWD/home"
      mkdir "$HOME"
      git config --global user.email "you@example.com"
      git config --global user.name  "Your Name"

      O=$("$go" 2>&1) && fail "Shouldn't succeed with no dir\n$O"

      function makeGit {
        pushd project
          git init .
          git add -A
          git commit -m "Initial commit"
          sed -e 's/42/24/g' -i b/x.py
          git add b/x.py
          git commit -m "Swap number"
        popd
      }

      cp -r "$project" project
      chmod +w -R project
      makeGit project
      dir="$PWD/project" "$go" || fail "Didn't benchmark bare project"
      [[ -e results ]]         || fail "No results dir found when bare"
      [[ -e html    ]]         || fail "No html dir found when bare"
      rm -rf results html project

      cp -r "$project" project
      chmod +w -R project
      mv project/x.nix project/default.nix
      sed -e 's@/x.nix@@g' -i project/asv.conf.json
      makeGit project
      dir="$PWD/project" "$go" || fail "Didn't benchmark nix-shell project"
      [[ -e results ]]         || fail "No results dir found when nix-shell"
      [[ -e html    ]]         || fail "No html dir found when nix-shell"
      rm -rf results html

      dir="$PWD/project" cacheDir="$PWD/cache" "$go" ||
        fail "Didn't work with empty cache"

      [[ -e cache   ]] || fail "No cache dir made"
      [[ -e results ]] || fail "No results made when caching"
      [[ -e html    ]] || fail "No html made when cachine"

      FOUND=0
      while read -r D
      do
        FOUND=1
      done < <(find cache -type d -name "*-test")
      [[ "$FOUND" -eq 1 ]] || fail "Didn't find cached result"
      unset FOUND
      rm -rf results html

      dir="$PWD/project" cacheDir="$PWD/cache" "$go" ||
        fail "Didn't work with populated cache"
      [[ -e results ]] || fail "No results when cached"
      [[ -e html    ]] || fail "No html when cached"
      rm -rf results html

      dir="$PWD/project" commitCount=1 "$go" ||
        fail "Didn't work with a commitCount"
      [[ -e results ]] || fail "No results with commitCount"
      [[ -e html    ]] || fail "No html with commitCount"
      FOUND=0
      for F in results/dummy/*.json
      do
        echo "$F" | grep 'machine.json' > /dev/null && continue
        FOUND=$(( FOUND + 1 ))
      done
      [[ "$FOUND" -eq 1 ]] || {
        find results 1>&2
        fail "commitCount 1 should only benchmark 1 commit"
      }
      unset FOUND
      rm -rf results html

      dir="$PWD/project" commitCount=5 "$go" ||
        fail "Didn't work with too-high commitCount"
      [[ -e results ]] || fail "No results with too-high commitCount"
      [[ -e html    ]] || fail "No html with too-high commitCount"
      FOUND=0
      for F in results/dummy/*.json
      do
        echo "$F" | grep 'machine.json' > /dev/null && continue
        FOUND=$(( FOUND + 1 ))
      done
      [[ "$FOUND" -eq 2 ]] || {
        find results 1>&2
        fail "Too-high commitCount should have benchmarked both commits"
      }
      unset FOUND
      rm -rf results html

      mkdir "$out"
    '';
};
withDeps [ test ] go
