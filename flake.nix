{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    flakepkgs = self.packages.x86_64-linux;
    frontendPerl = pkgs.perl.withPackages (ps: [
      ps.DBDSQLite
      ps.Mojolicious
      ps.MojoJWT
      ps.MojoSQLite
      ps.PrometheusTiny
      flakepkgs.MojoliciousPluginOAuth2
    ]);
    pythonEnv = pkgs.python3.withPackages (ps: with ps; [
      # aionotify
      asyncinotify
      certifi
      charset-normalizer
      click
      idna
      peewee
      python-gitlab
      requests
      requests-toolbelt
      urllib3
    ]);
  in {

    packages.x86_64-linux.hello = nixpkgs.legacyPackages.x86_64-linux.hello;

    packages.x86_64-linux.default = flakepkgs.hello;

    packages.x86_64-linux.frontend = pkgs.stdenv.mkDerivation {
      pname = "lrz-gitlab-classroom-frontend";
      version = "2026-01-19";
      src = ./frontend;
      buildInputs = [ frontendPerl ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      installPhase = ''
        mkdir -p $out/bin $out/share/templates
        cp -r templates/* $out/share/templates/
        cp app.pl $out/share/app.pl
        makeWrapper ${frontendPerl}/bin/perl $out/bin/lrz-gitlab-classroom-frontend \
          --add-flags "$out/share/app.pl"
      '';
    };


    # { lib
    #   , buildPythonPackage
    #   , fetchFromGitHub
    #   , asynctest
    #   , pythonOlder
    #   }:

    packages.x86_64-linux.aionotify = pkgs.python3Packages.buildPythonPackage rec {
      pname = "aionotify";
      version = "0.3.1";
      pyproject = true;

      src = pkgs.fetchFromGitHub {
        owner = "rbarrois";
        repo = "aionotify";
        rev = version;
        sha256 = "sha256-OuFTFnoxB14I2k7OXVoZNWsX33lKe86KUJnKRSB4CNw=";
      };

      checkInputs = with pkgs.python3Packages; [
        # asynctest
      ];

      meta = with pkgs.lib; {
        homepage = "https://github.com/rbarrois/aionotify";
        description = "Simple, asyncio-based inotify library for Python";
        license = with pkgs.lib.licenses; [ bsd2 ];
        platforms = platforms.linux;
        maintainers = with lib.maintainers; [ pogobanane ];
      };
    };

    packages.x86_64-linux.MojoliciousPluginOAuth2 = pkgs.perlPackages.buildPerlPackage {
      pname = "Mojolicious-Plugin-OAuth2";
      version = "2.02";
      src = pkgs.fetchurl {
        url = "mirror://cpan/authors/id/J/JH/JHTHORSEN/Mojolicious-Plugin-OAuth2-2.02.tar.gz";
        hash = "sha256-E0kPucaJR+ZbFDrenWsPQnC0EhV+rFdyH3rUl8NHIYE=";
      };
      propagatedBuildInputs = with pkgs.perlPackages; [ IOSocketSSL Mojolicious ];
      meta = {
        homepage = "https://github.com/marcusramberg/Mojolicious-Plugin-OAuth2";
        description = "Auth against OAuth2 APIs including OpenID Connect";
        license = pkgs.lib.licenses.artistic2;
      };
    };

    devShells.x86_64-linux.default = pkgs.mkShell {
      buildInputs = with pkgs; [
        jq
        sqlite
        frontendPerl
        pythonEnv
      ];
    };

  };
}
