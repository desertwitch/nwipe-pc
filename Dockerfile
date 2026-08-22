FROM alpine:3.22

ARG BRANCH=master
ARG COMMIT=unknown
ARG LIBNVME_VERSION=1.16.1
ARG NWIPE_GIT_HASH=${COMMIT}

ENV TERM=xterm

WORKDIR /tmp/nwipe
COPY . /tmp/nwipe

RUN apk update && \
    apk upgrade && \
    apk add --no-cache \
        bash \
        automake \
        make \
        curl \
        ncurses-dev \
        libevent \
        parted-dev \
        libconfig-dev \
        hdparm \
        dmidecode \
        smartmontools \
        autoconf \
        gcc \
        g++ \
        linux-headers \
        meson \
        ninja \
        json-c-dev \
        wget && \
    cd /tmp && \
    wget "https://github.com/linux-nvme/libnvme/archive/refs/tags/v${LIBNVME_VERSION}.tar.gz" && \
    tar xvfz "v${LIBNVME_VERSION}.tar.gz" && \
    cd "libnvme-${LIBNVME_VERSION}" && \
    meson setup .build && \
    meson compile -C .build && \
    meson install -C .build && \
    ldconfig /usr/local/lib && \
    cd /tmp && \
    rm -rf "libnvme-${LIBNVME_VERSION}" "v${LIBNVME_VERSION}.tar.gz" && \
    cd /tmp/nwipe && \
    if [ "$BRANCH" = "devel" ]; then \
      SHORT=$(echo "$COMMIT" | cut -c1-7) && \
      sed -i "s/const char\* banner = \"nwipe-pc /const char* banner = \"(${SHORT}-DEVEL) nwipe-pc /" src/version.c; \
    fi && \
    ash autogen.sh && \
    ash configure --with-libnvme && \
    make && \
    make install && \
    cd /tmp && \
    apk del bash automake make autoconf gcc g++ meson ninja wget && \
    rm -rf nwipe && \
    ldd /usr/local/bin/nwipe && \
    /usr/local/bin/nwipe -V

WORKDIR /app

CMD ["/usr/local/bin/nwipe"]
