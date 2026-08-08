{
  description = "Hivemind Kafka Playground";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          just
          zellij
          kcat
          kafkactl
          nodejs
          postgresql # psql client for the materialize example
          jq
          yq-go
          yamlfmt
          yamllint
          mdformat
          nixfmt
          bash
          lazysql
          openjdk25 # the kafka-2-kafka-json-redaction Scala apps
          maven
        ];

        # Everything local, so every tool's config, cache and temp path resolves
        # inside the project. This is the single source of truth, and
        # .claude/settings.json mirrors it with absolute paths because its `env`
        # block does not expand variables. scripts/validate.sh fails if the two
        # drift. Paths are relative to the shell's cwd, which direnv and
        # `nix develop` set to the repo root.
        shellHook = ''
          export TMPDIR="$PWD/.tmp"
          # zsh writes heredoc bodies here rather than to $TMPDIR
          export TMPPREFIX="$PWD/.tmp/zsh"
          export XDG_CACHE_HOME="$PWD/.cache"
          export npm_config_cache="$PWD/.cache/npm"
          export NPM_CONFIG_USERCONFIG="$PWD/.npmrc" # need not exist
          export DOCKER_CONFIG="$PWD/.docker"
          export KCAT_CONFIG="$PWD/.config/kcat.conf" # kcat exits 1 without it
          export KAFKA_CTL_CONFIG="$PWD/.config/kafkactl.yml"
          export PSQLRC="$PWD/.config/psqlrc" # need not exist
          export PSQL_HISTORY="$PWD/.tmp/psql_history"
          export CURL_HOME="$PWD/.config" # curl reads $CURL_HOME/.curlrc first
          # Maven has no dedicated variable for its local repository, so its own
          # MAVEN_ARGS (Maven >= 3.9) carries it. That makes this the one value
          # here holding more than one $PWD path, since java.io.tmpdir rides
          # along as a *user property*, which is what lets the poms point forked
          # JVMs at the same directory without hardcoding an absolute path.
          export MAVEN_ARGS="-Dmaven.repo.local=$PWD/.cache/maven -Djava.io.tmpdir=$PWD/.tmp"
          # The Maven JVM's own temp directory, which MAVEN_ARGS cannot set:
          # a -D on the Maven command line arrives long after the JVM read
          # java.io.tmpdir. Without this, jansi unpacks its native library to
          # /tmp on every invocation.
          export MAVEN_OPTS="-Djava.io.tmpdir=$PWD/.tmp"
          mkdir -p "$TMPDIR" "$XDG_CACHE_HOME"
        '';
      };
    };
}
