# Thin Fedora dev environment for Godot projects.
#
# This image deliberately installs NO Godot, Blender, dotnet or BespokeSynth.
# Those all come from the host via ~/Programs, which is visible because
# devcontainer.json bind-mounts the whole of $HOME. That is the entire point:
# the editor/LSP running on the host and the tooling running in here are the
# same binaries, so the Godot language server and the Blender MCP socket are
# shared rather than duplicated.
#
# What DOES belong here: things you want isolated per-project and reproducible,
# i.e. the C/C++ toolchain and SCons used to build GDExtensions.

FROM fedora:44

# Three distinct groups, for three distinct reasons:
#
# 1. RUNTIME LIBRARIES FOR THE HOST TOOLS. This is the cost of borrowing
#    binaries from ~/Programs instead of installing them: the binaries are the
#    host's, but the shared libraries they load must exist *in here*. The X11/GL
#    set below is exactly blender's DT_NEEDED list (verified with ldd) -- it is
#    required even for `blender --background`, because those are load-time deps,
#    not GUI-only ones.
#
#    libicu is the subtle one. .NET *dlopens* libicuuc.so from
#    libSystem.Globalization.Native.so, so it never appears in ldd output and the
#    failure surfaces only at runtime as "Couldn't find a valid ICU package".
#    Fedora 44's `libicu` is 77.1; do NOT use the `libicu76` compat package.
#
# 2. BUILD TOOLCHAIN for GDExtensions. python3-scons (not "scons") is the Fedora
#    package name; it provides /usr/bin/scons, so SConstructs can be invoked as
#    `scons` directly rather than `python3 -m SCons`.
#
#    libstdc++-static is NOT optional. godot-cpp sets use_static_cpp=True by
#    default (tools/linux.py) and links every extension with
#    `-static-libgcc -static-libstdc++`, which needs libstdc++.a. On Fedora that
#    lives in its own package -- gcc-c++ pulls in libstdc++-devel, which provides
#    only the shared .so. Without it the compile succeeds and the LINK fails with
#    "cannot find -lstdc++ ... have you installed the static version". Ubuntu's
#    build-essential bundled the static lib, which is why this never surfaced
#    before. Costs ~57MB, and project-redline (C#) does not need it, but the
#    Dockerfile is deliberately identical across all the Godot projects.
#
# 3. CLI conveniences.
RUN dnf install -y --setopt=install_weak_deps=False \
        libicu openssl-libs krb5-libs zlib ca-certificates \
        libX11 libXau libxcb libXext libXfixes libXi libXrender libxkbcommon \
        libICE libSM libuuid libglvnd libglvnd-glx vulkan-loader libgomp \
        fontconfig \
        python3-scons gcc gcc-c++ libstdc++-static make cmake \
        pkgconf-pkg-config python3-devel \
        git git-lfs openssh-clients \
        which findutils procps-ng ripgrep jq unzip xz sudo \
    && dnf clean all

# UID 1000 matches the host user; --userns=keep-id in devcontainer.json maps
# host 1000 -> container 1000 so the bind-mounted $HOME is owned correctly.
ARG USERNAME=eir
ARG USER_UID=1000
RUN useradd --uid ${USER_UID} --user-group --create-home ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

# Host tool shims (~/Programs/bin holds godot, godot4.6, godot-csharp, blender,
# dotnet). Set here rather than relying on ~/.bashrc so that non-interactive
# processes -- VS Code tasks and the C#/Godot extension hosts -- also see them.
ENV PATH="/home/${USERNAME}/Programs/bin:/home/${USERNAME}/.local/bin:${PATH}"
ENV LANG=en_US.UTF-8

USER ${USERNAME}
