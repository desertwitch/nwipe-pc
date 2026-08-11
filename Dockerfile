FROM alpine:3.22

ARG BRANCH=master
ARG COMMIT=unknown

WORKDIR /tmp/nwipe

RUN apk update && \
    apk upgrade && \
    apk add --no-cache \
        git \
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
    wget https://github.com/linux-nvme/libnvme/archive/refs/tags/v1.16.1.tar.gz && \
    tar xvfz v1.16.1.tar.gz && \
    cd libnvme-1.16.1 && \
    meson setup .build && \
    meson compile -C .build && \
    meson install -C .build && \
    ldconfig /usr/local/lib || true && \
    cd /tmp && \
    rm -rf libnvme-1.16.1 v1.16.1.tar.gz && \
    cd /tmp/nwipe && \
    git clone --branch ${BRANCH} https://github.com/desertwitch/nwipe-pc.git . && \
    if [ "$BRANCH" = "devel" ]; then \
      SHORT=$(echo "$COMMIT" | cut -c1-7) && \
      sed -i "s/const char\* banner = \"nwipe-pc /const char* banner = \"(${SHORT}-DEVEL) nwipe-pc /" src/version.c; \
    fi && \
    ash autogen.sh && \
    ash configure --with-libnvme && \
    make && \
    make install && \
    cd /tmp && \
    apk del git automake make autoconf gcc g++ meson ninja wget && \
    rm -rf nwipe

WORKDIR /app

ENV TERM=xterm

CMD ["/usr/local/bin/nwipe"]
