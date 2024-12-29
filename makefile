
RUN := docker compose run --rm --remove-orphans

test:
	zig test src/server.zig

run:
	docker compose up -d

down:
	docker compose down

shell:
	${RUN} shell

client:
	${RUN} client

server:
	${RUN} server

build:
	docker build . -t zig-memstore:latest
