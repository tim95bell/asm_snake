
#!/bin/bash

pushd $(dirname $0)/..
set -e

rm -rf ./libs/raylib
rm -rf ./external/raylib/build
cmake -GXcode -B./external/raylib/build -S./external/raylib -DCMAKE_INSTALL_PREFIX=./libs/raylib
cmake --build ./external/raylib/build --config Debug --target install

popd
