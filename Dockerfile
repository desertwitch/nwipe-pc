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
        linux-headers && \
    git clone --branch ${BRANCH} https://github.com/desertwitch/nwipe-pc.git . && \
    if [ "$BRANCH" = "devel" ]; then \
      SHORT=$(echo "$COMMIT" | cut -c1-7) && \
      sed -i "s/const char\* banner = \"nwipe-pc /const char* banner = \"(${SHORT}-DEVEL) nwipe-pc /" src/version.c; \
    fi && \
    ash autogen.sh && \
    ash configure && \
    make && \
    make install && \
    cd /tmp && \
    apk del git automake make autoconf gcc g++ && \
    rm -rf nwipe

WORKDIR /app

ENV TERM=xterm

CMD ["/usr/local/bin/nwipe"]
