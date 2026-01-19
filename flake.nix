{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    flakepkgs = self.packages.x86_64-linux;
  in {

    packages.x86_64-linux.hello = nixpkgs.legacyPackages.x86_64-linux.hello;

    packages.x86_64-linux.default = flakepkgs.hello;

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
        (perl.withPackages (ps: [
          ps.DBDSQLite
          ps.Mojolicious
          ps.MojoJWT
          ps.MojoSQLite
          ps.PrometheusTiny
          flakepkgs.MojoliciousPluginOAuth2
        ]))
      ];
    };

  };
}
