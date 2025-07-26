FROM mcr.microsoft.com/devcontainers/base:bullseye AS build
WORKDIR /app

CMD ["bash"]

ENV ZIG_VERSION=linux-x86_64-0.14.1

RUN curl -sS https://ziglang.org/builds/zig-$ZIG_VERSION.tar.xz > archive.tar.xz \
    && ls -al /app \
    && tar -xf archive.tar.xz \
    && rm archive.tar.xz

ENV PATH=/app/zig-$ZIG_VERSION:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY /src /app/src
COPY build.zig /app/build.zig

RUN zig build -freference-trace=10

FROM ubuntu
WORKDIR /app
COPY --from=build /app/zig-out/bin/zig-memstore /bin/zig-memstore
COPY --from=build /app/zig-out/bin/zig-memstore-client /bin/zig-memstore-client
ENTRYPOINT [ "/bin/zig-memstore", "9876" ]
