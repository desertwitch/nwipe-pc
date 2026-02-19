FROM alpine:3.22

ARG BRANCH=master
ARG COMMIT=unknown

RUN apk add --no-cache git && \
    git clone --branch ${BRANCH} https://github.com/desertwitch/nwipe-pc.git /tmp/nwipe

WORKDIR /tmp/nwipe

RUN if [ "$BRANCH" = "devel" ]; then \
      SHORT=$(echo "$COMMIT" | cut -c1-7) && \
      sed -i "s/const char\* banner = \"nwipe-pc /const char* banner = \"(${SHORT}-DEVEL) nwipe-pc /" src/version.c; \
    fi

RUN apk update && \
    apk upgrade && \
    apk add --no-cache \
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
    ash autogen.sh && \
    ash configure && \
    make && \
    make install && \
    cd /tmp && \
    apk del automake make autoconf gcc g++ git && \
    rm -rf nwipe

WORKDIR /app

ENV TERM=xterm

CMD ["/usr/local/bin/nwipe"]
