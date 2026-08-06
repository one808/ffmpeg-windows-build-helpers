FROM docker.io/library/debian:12-slim

# Build-time dependencies for mingw-w64-build-r33 and cross_compile_ffmpeg.sh.
# The scripts build their own nasm/python/cmake/etc from source and install
# them under /usr inside this image -- that's fine, this container is
# disposable and never touches the host.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    p7zip-full \
    autoconf \
    autogen \
    automake \
    bison \
    bzip2 \
    cmake \
    cvs \
    ed \
    flex \
    g++ \
    gcc \
    git \
    gperf \
    mercurial \
    libtool \
    libtool-bin \
    make \
    texinfo \
    patch \
    pax \
    pkg-config \
    subversion \
    unzip \
    wget \
    xz-utils \
    yasm \
    curl \
    build-essential \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# check_missing_packages() in cross_compile_ffmpeg.sh writes an RPM-style
# ca-trust marker file; fake it with Debian's real CA bundle so the script's
# own wget-based cert refresh step is skipped instead of failing.
RUN mkdir -p /etc/pki/ca-trust/extracted/pem && \
    cp /etc/ssl/certs/ca-certificates.crt /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem && \
    touch /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.done

RUN printf '[extensions]\npurge =\n' > /root/.hgrc

WORKDIR /work
