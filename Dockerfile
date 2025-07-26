FROM mcr.microsoft.com/devcontainers/base:bullseye AS build
WORKDIR /app

CMD ["bash"]

ARG ZIG_VERSION=0.14.1
ARG ARCH=x86_64
ARG ZIG_FOLDER=zig-$ARCH-linux-$ZIG_VERSION
ARG ZIG_URL=https://ziglang.org/download/0.14.1/$ZIG_FOLDER.tar.xz

RUN curl -sS $ZIG_URL > archive.tar.xz \
    && ls -al /app \
    && tar -xf archive.tar.xz \
    && rm archive.tar.xz

ENV PATH=/app/$ZIG_FOLDER:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY /src /app/src
COPY build.zig /app/build.zig

RUN zig build -freference-trace=10

FROM ubuntu
WORKDIR /app
COPY --from=build /app/zig-out/bin/zig-memstore /bin/zig-memstore
COPY --from=build /app/zig-out/bin/zig-memstore-client /bin/zig-memstore-client
ENTRYPOINT [ "/bin/zig-memstore", "9876" ]
