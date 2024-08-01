
#!/bin/bash

pushd $(dirname $0)/..
set -e

BUILD_DIR=./build
rm -rf $BUILD_DIR
mkdir -p $BUILD_DIR

OBJECT_FILE_DIR=$BUILD_DIR/object_files
mkdir -p $OBJECT_FILE_DIR

as -g -Wall -o $OBJECT_FILE_DIR/main.o ./src/main.S
ld -o $BUILD_DIR/snake $OBJECT_FILE_DIR/main.o -L./libs/raylib/lib -lraylib -framework OpenGL -framework CoreVideo -framework IOKit -framework Cocoa -lSystem -syslibroot `xcrun -sdk macosx --show-sdk-path` -e _main -arch arm64

popd
