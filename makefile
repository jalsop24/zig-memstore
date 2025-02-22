
RUN := docker compose run --rm --remove-orphans --build -v "$(shell pwd)/.zig-cache:/app/.zig-cache/"
TEST := zig build test --summary all

ci-test:
	${TEST}

test:
	${RUN} --entrypoint="${TEST}" shell

benchmark:
	${RUN} --entrypoint="zig build benchmark --summary all" shell

run:
	docker compose up -d --build server

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
