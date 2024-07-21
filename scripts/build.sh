
#!/bin/bash

pushd $(dirname $0)/..
set -e

BUILD_DIR=./build
rm -rf $BUILD_DIR
mkdir -p $BUILD_DIR

# FLAGS="-Wall -g"
# SRC_FILES="./src/main.S"
# clang++ $FLAGS $SRC_FILES -o $BUILD_DIR/snake -I./libs/raylib/include -L./libs/raylib/lib -lraylib -Wl,-framework,OpenGL -Wl,-framework,CoreVideo -Wl,-framework,IOKit -Wl,-framework,Cocoa

PRE_PROCESSED_OUTPUT_DIR=$BUILD_DIR/pre_processed
OBJECT_FILE_DIR=$BUILD_DIR/object_files
mkdir -p $PRE_PROCESSED_OUTPUT_DIR
mkdir -p $OBJECT_FILE_DIR

cpp -g ./src/main.S $PRE_PROCESSED_OUTPUT_DIR/main.S
as -g -Wall -o $OBJECT_FILE_DIR/main.o $PRE_PROCESSED_OUTPUT_DIR/main.S
ld -o $BUILD_DIR/snake $OBJECT_FILE_DIR/main.o -L./libs/raylib/lib -lraylib -framework OpenGL -framework CoreVideo -framework IOKit -framework Cocoa -lSystem -syslibroot `xcrun -sdk macosx --show-sdk-path` -e _main -arch arm64

popd
