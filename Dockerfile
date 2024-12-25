FROM mcr.microsoft.com/devcontainers/base:bullseye AS build
WORKDIR /app

CMD ["bash"]

RUN curl -sS https://ziglang.org/download/0.13.0/zig-linux-aarch64-0.13.0.tar.xz > archive.tar.xz \
    && ls -al /app \
    && tar -xf archive.tar.xz \
    && rm archive.tar.xz

ENV PATH=/app/zig-linux-aarch64-0.13.0:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY /src /app/src
COPY build.zig /app/build.zig

RUN zig build

FROM ubuntu
WORKDIR /app
COPY --from=build /app/zig-out/bin/zig-memstore /bin/zig-memstore
COPY --from=build /app/zig-out/bin/zig-memstore-client /bin/zig-memstore-client
ENTRYPOINT [ "/bin/zig-memstore", "9876" ]