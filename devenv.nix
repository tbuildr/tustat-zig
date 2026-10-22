{pkgs, ...}: {
  # Provides zig + zls. tustat targets Zig 0.16.0 — check what nixpkgs
  # gives you with `zig version` inside the shell. If it's not 0.16.x,
  # pin it explicitly, e.g.:
  #   package = pkgs.zig_0_16;
  # (confirm the attribute exists: nix eval nixpkgs#zig_0_16.version)
  languages.zig.enable = true;
}
