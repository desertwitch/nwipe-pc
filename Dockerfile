FROM alpine:3.22

LABEL org.opencontainers.image.source=https://github.com/desertwitch/nwipe-pc
LABEL org.opencontainers.image.description="nwipe secure disk eraser, with patched-in support for pre-clearing disks for Unraid."

ADD https://github.com/desertwitch/nwipe-pc.git /tmp/nwipe

WORKDIR /tmp/nwipe

ENV TERM=xterm

RUN apk update && \
    apk upgrade && \
    apk add \
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
    apk del automake make autoconf gcc g++ && \
    rm -rf nwipe

WORKDIR /app

CMD ["/usr/local/bin/nwipe"]
