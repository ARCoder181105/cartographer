.PHONY: all parser engine frontend test clean

all: parser engine frontend

parser:
	cd parser && cmake -B build -DCMAKE_BUILD_TYPE=Release -G "MinGW Makefiles" && cmake --build build

engine:
	cd engine && go build -o bin/cartographer-engine .

frontend:
	cd frontend && npm run build

test:
	cd engine && go test ./...
	cd frontend && npm run test

clean:
	rm -rf parser/build engine/bin frontend/dist