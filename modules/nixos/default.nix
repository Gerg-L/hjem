linker: {
  config,
  pkgs,
  lib,
  utils,
  ...
}: let
  inherit (lib.modules) mkIf;
  inherit (lib.options) mkOption literalExpression;
  inherit (lib.lists) concatLists;
  inherit (lib.trivial) pipe;
  inherit (lib.strings) optionalString;
  inherit (lib.attrsets) mapAttrsToList;
  inherit (lib.types) bool attrsOf submoduleWith listOf raw attrs submodule;
  inherit (builtins) filter attrValues mapAttrs hasAttr getAttr;

  cfg = config.hjem;

  hjemModule = submoduleWith {
    description = "Hjem NixOS module";
    class = "hjem";
    specialArgs =
      cfg.specialArgs
      // {
        inherit pkgs;
        osConfig = config;
      };
    modules =
      [
        (import ../common.nix linker)
        ({name, ...}: let
          user = getAttr name config.users.users;
        in {
          user = user.name;
          directory = user.home;
          clobberFiles = cfg.clobberByDefault;
        })
      ]
      ++
      # Evaluate additional modules under 'hjem.users.<name>' so that
      # module systems built on Hjem are more ergonomic.
      cfg.extraModules;
  };
in {
  options.hjem = {
    clobberByDefault = mkOption {
      type = bool;
      default = false;
      description = ''
        The default override behaviour for files managed by Hjem.

        While `true`, existing files will be overriden with new files on rebuild.
        The behaviour may be modified per-user by setting {option}`hjem.users.<name>.clobberFiles`
        to the desired value.
      '';
    };

    users = mkOption {
      default = {};
      type = attrsOf hjemModule;
      description = "Home configurations to be managed";
    };

    extraModules = mkOption {
      type = listOf raw;
      default = [];
      description = ''
        Additional modules to be evaluated as a part of the users module
        inside {option}`config.hjem.users.<name>`. This can be used to
        extend each user configuration with additional options.
      '';
    };

    specialArgs = mkOption {
      type = attrs;
      default = {};
      example = literalExpression "{ inherit inputs; }";
      description = ''
        Additional `specialArgs` are passed to Hjem, allowing extra arguments
        to be passed down to to all imported modules.
      '';
    };

    options.users.users = mkOption {
      type = attrsOf (submodule ({name, ...}: {
        packages = mkIf (hasAttr name cfg.users) cfg.users.packages;
      }));
    };

    useLinker = mkOption {
      type = bool;
      default = false;
      example = true;
      description = ''
        Method to use to link files.
        `false` will use `systemd-tmpfiles`, which is only supported on Linux.
        This is the default file linker on Linux, as it is the more mature linker, but it has the downside of leaving
        behind symlinks that may not get invalidated until the next GC, if an entry is removed from {option}`hjem.<user>.files`.
        Specifying a package will use a custom file linker that uses an internally-generated manifest.
        The custom file linker must use this manifest to create or remove links as needed, by comparing the
        manifest of the currently activated system with that of the new system.
        This prevents dangling symlinks when an entry is removed from {option}`hjem.<user>.files`.
        This linker is currently experimental; once it matures, it may become the default in the future.
      '';
    };
  };

  config = {
    # Constructed rule string that consists of the type, target, and source
    # of a tmpfile. Files with 'null' sources are filtered before the rule
    # is constructed.
    systemd.user.tmpfiles.users = mkIf (! cfg.useLinker) (
      mapAttrs (_: {
        enable,
        files,
        ...
      }: {
        rules =
          mkIf enable
          (
            pipe files [
              attrValues
              (filter (f: f.enable && f.source != null))
              (map (
                file:
                # L+ will recreate, i.e., clobber existing files.
                "L${optionalString file.clobber "+"} '${file.target}' - - - - ${file.source}"
              ))
            ]
          );
      })
      cfg.users
    );

    # steal from: https://github.com/nix-community/home-manager/blob/master/nixos/default.nix
    systemd.services =
      lib.mapAttrs' (
        _: user:
          lib.nameValuePair "hjem-${utils.escapeSystemdPath user.user}" {
            description = "hjem for ${user.user}";
            wantedBy = ["multi-user.target"];
            wants = ["nix-daemon.socket"];
            after = ["nix-daemon.socket"];
            before = ["systemd-user-sessions.service"];

            unitConfig = {
              RequiresMountsFor = user.directory;
            };
            stopIfChanged = false;
            serviceConfig = {
              User = user.user;
              Type = "oneshot";
              TimeoutStartSec = "5m";
              SyslogIdentifier = "hjem-${utils.escapeSystemdPath user.user}";
              execStart = let
                exportedSystemdVariables = lib.concatStringsSep "|" [
                  "DBUS_SESSION_BUS_ADDRESS"
                  "DISPLAY"
                  "WAYLAND_DISPLAY"
                  "XAUTHORITY"
                  "XDG_RUNTIME_DIR"
                ];
                packages = [pkgs.gnused];
              in
                pkgs.writeScript "hm-setup-env" ''
                  #! ${pkgs.runtimeShell} -el
                  export PATH=$PATH:${lib.makeBinPath packages}

                  # The activation script is run by a login shell to make sure
                  # that the user is given a sane environment.
                  # If the user is logged in, import variables from their current
                  # session environment.
                  eval "$(
                    XDG_RUNTIME_DIR=\''${XDG_RUNTIME_DIR:-/run/user/$UID} systemctl --user show-environment 2> /dev/null \
                    | sed -En '/^(${exportedSystemdVariables})=/s/^/export /p'
                  )"

                  exec "${user.activationPackage}/activate"
                '';
            };
          }
      )
      cfg.users;
    warnings =
      concatLists
      (mapAttrsToList (
          user: v:
            map (
              warning: "${user} profile: ${warning}"
            )
            v.warnings
        )
        cfg.users);

    assertions =
      concatLists
      (mapAttrsToList (user: config:
        map ({
          assertion,
          message,
          ...
        }: {
          inherit assertion;
          message = "${user} profile: ${message}";
        })
        config.assertions)
      cfg.users);
  };
  _file = ./default.nix;
}
