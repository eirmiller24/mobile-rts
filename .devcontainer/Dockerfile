FROM ubuntu:26.04

RUN apt-get update && apt-get install -y locales git && \
    locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8

RUN apt-get update && apt-get install -y software-properties-common && \
    add-apt-repository ppa:deadsnakes/ppa

RUN apt-get update && apt-get install -y \
    openssh-client libgomp1 xz-utils libxrender1 \
    libxtst6 libxi6 libxkbcommon0 libxxf86vm1 \
    libxfixes3 libgl1 libglx-mesa0 libsm6 libice6 \
    libx11-6 curl libpython3.13 build-essential

RUN curl -L https://download.blender.org/release/Blender4.2/blender-4.2.19-linux-x64.tar.xz | \
    tar -xJ -C /opt && \
    ln -s /opt/blender-4.2.19-linux-x64/blender /usr/local/bin/blender

RUN curl -L https://download.opensuse.org/repositories/home:/bespokesynth/Debian_13/amd64/bespokesynth_1.3.0-0_amd64.deb -o /tmp/bespokesynth.deb && \
    apt-get install -y /tmp/bespokesynth.deb && \
    rm /tmp/bespokesynth.deb

ARG USERNAME=eir
ARG USER_UID=1000
ARG USER_GID=1000
RUN if ! getent group $USER_GID > /dev/null 2>&1; then \
        groupadd --gid $USER_GID $USERNAME; \
    else \
        groupmod -n $USERNAME $(getent group $USER_GID | cut -d: -f1); \
    fi \
    && if ! getent passwd $USER_UID > /dev/null 2>&1; then \
        useradd --uid $USER_UID --gid $USER_GID -m $USERNAME; \
    else \
        usermod -l $USERNAME -d /home/$USERNAME -m $(getent passwd $USER_UID | cut -d: -f1); \
    fi

ENTRYPOINT ["/bin/sh"]