clang -shared -o librenderer.dylib renderer.m \
  -framework Cocoa \
  -framework Metal \
  -framework QuartzCore \
  -arch arm64
