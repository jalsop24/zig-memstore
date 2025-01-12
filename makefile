
RUN := docker compose run --rm --remove-orphans --build
TEST := zig test ./src/server.zig 

test:
	${RUN} --entrypoint="${TEST}" shell

run:
	docker compose up -d --build

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
