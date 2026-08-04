{
  description = "Dev shell for review-loop.nvim (nvim + plenary + luacheck)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Pinned plenary source. scripts/test and tests/minimal_init.vim both honor
  # PLENARY_PATH, so the suite runs deterministically without a lazy install.
  inputs.plenary-nvim.url = "github:nvim-lua/plenary.nvim";
  inputs.plenary-nvim.flake = false;

  outputs = { self, nixpkgs, plenary-nvim }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              neovim # >= 0.10 on nixos-unstable: vim.system, vim.base64, extmark sign_text
              luajitPackages.luacheck # linter (luacheck moved off the top-level attr set)
              git
              gzip # checkpoint content codec
            ];

            # Exposed to the shell; scripts/test + minimal_init.vim consume it.
            PLENARY_PATH = "${plenary-nvim}";
          };
        });

      # Convenience: `nix flake check` stays green (no buildable outputs).
      formatter = forAllSystems (system:
        nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
