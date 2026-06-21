/*

Copyright 2026 Carl Dea

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://apache.org

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and limitations under the License.
*/
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

// --- SHADERS ---
static NSString *const shaderSource = @""
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct Uniforms {\n"
    "    float4x4 modelViewProjectionMatrix;\n"
    "};\n"
    "\n"
    "struct VertexOut {\n"
    "    float4 position [[position]];\n"
    "    float4 color;\n"
    "};\n"
    "\n"
    "// 2D Vertex Shader\n"
    "vertex VertexOut vertexShader2D(uint vertexID [[vertex_id]]) {\n"
    "    float2 positions[3] = { float2(0.0, 0.5), float2(-0.5, -0.5), float2(0.5, -0.5) };\n"
    "    float4 colors[3] = { float4(1,0,0,1), float4(0,1,0,1), float4(0,0,1,1) };\n"
    "    VertexOut out;\n"
    "    out.position = float4(positions[vertexID], 0.0, 1.0);\n"
    "    out.color = colors[vertexID];\n"
    "    return out;\n"
    "}\n"
    "\n"
    "// 3D Vertex Shader\n"
    "struct Vertex3DIn {\n"
    "    float3 position [[attribute(0)]];\n"
    "    float4 color    [[attribute(1)]];\n"
    "};\n"
    "\n"
    "vertex VertexOut vertexShader3D(Vertex3DIn in [[stage_in]],\n"
    "                               constant Uniforms& uniforms [[buffer(1)]]) {\n"
    "    VertexOut out;\n"
    "    out.position = uniforms.modelViewProjectionMatrix * float4(in.position, 1.0);\n"
    "    out.color = in.color;\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 fragmentShader(VertexOut in [[stage_in]]) {\n"
    "    return in.color;\n"
    "}\n";

// --- STRUCTS ---
typedef struct {
    simd_float3 position;
    simd_float4 color;
} Vertex3D;

typedef struct {
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    id<MTLRenderPipelineState> pipelineState2D;
    id<MTLRenderPipelineState> pipelineState3D;
    id<MTLBuffer> vertexBuffer3D;
    CAMetalLayer *metalLayer;
    NSWindow *parentWindow;
    NSWindow *childWindow;
    NSView *metalView;
    float animationPhase;
    float globalAlpha;
    int renderMode; 
    float rotationX;
    float rotationY;
} MetalRenderer;

// --- SIMD MATRIX MATH HELPERS ---
static simd_float4x4 matrix_identity(void) {
    return (simd_float4x4){{
        { 1, 0, 0, 0 },
        { 0, 1, 0, 0 },
        { 0, 0, 1, 0 },
        { 0, 0, 0, 1 }
    }};
}

static simd_float4x4 matrix_rotation(float rx, float ry) {
    float cx = cosf(rx), sx = sinf(rx);
    float cy = cosf(ry), sy = sinf(ry);
    
    simd_float4x4 rotX = {{
        { 1,   0,   0, 0 },
        { 0,  cx,  sx, 0 },
        { 0, -sx,  cx, 0 },
        { 0,   0,   0, 1 }
    }};
    
    simd_float4x4 rotY = {{
        {  cy, 0, -sy, 0 },
        {   0, 1,   0, 0 },
        {  sy, 0,  cy, 0 },
        {   0, 0,   0, 1 }
    }};
    
    return simd_mul(rotX, rotY);
}

static simd_float4x4 matrix_perspective(float fovRadians, float aspect, float nearZ, float farZ) {
    float ys = 1.0f / tanf(fovRadians * 0.5f);
    float xs = ys / aspect;
    float zs = farZ / (nearZ - farZ);
    float wz = (nearZ * farZ) / (nearZ - farZ);
    
    return (simd_float4x4){{
        { xs,  0,  0,  0 },
        {  0, ys,  0,  0 },
        {  0,  0, zs, -1 },
        {  0,  0, wz,  0 }
    }};
}

static void execute_on_main_thread(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

// --- LIFE CYCLE FUNCTIONS ---
__attribute__((visibility("default")))
void* init_metal_renderer(void* nsWindowPtr) {
    if (!nsWindowPtr) return NULL;
    
    __block MetalRenderer *renderer = malloc(sizeof(MetalRenderer));
    renderer->animationPhase = 0.0f;
    renderer->globalAlpha = 0.4f;
    renderer->renderMode = 0; // Default to 2D
    renderer->rotationX = 0.0f;
    renderer->rotationY = 0.0f;
    renderer->parentWindow = (__bridge NSWindow*)nsWindowPtr;
    
    execute_on_main_thread(^{
        renderer->childWindow = [[NSWindow alloc] initWithContentRect:NSZeroRect
                                                            styleMask:NSWindowStyleMaskBorderless
                                                              backing:NSBackingStoreBuffered
                                                                defer:NO];
        [renderer->childWindow setOpaque:NO];
        [renderer->childWindow setBackgroundColor:[NSColor clearColor]];
        [renderer->childWindow setIgnoresMouseEvents:YES]; // Pass inputs to JavaFX
        
        renderer->metalView = [[NSView alloc] initWithFrame:NSZeroRect];
        renderer->device = MTLCreateSystemDefaultDevice();
        renderer->commandQueue = [renderer->device newCommandQueue];
        
        renderer->metalLayer = [CAMetalLayer layer];
        renderer->metalLayer.device = renderer->device;
        renderer->metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        renderer->metalLayer.framebufferOnly = YES;
        renderer->metalLayer.opaque = NO;
        
        [renderer->metalView setWantsLayer:YES];
        [renderer->metalView setLayer:renderer->metalLayer];
        [renderer->childWindow setContentView:renderer->metalView];
        [renderer->parentWindow addChildWindow:renderer->childWindow ordered:NSWindowAbove];
        
        NSError *error = nil;
        id<MTLLibrary> library = [renderer->device newLibraryWithSource:shaderSource options:nil error:&error];
        if (!library) {
            NSLog(@"Shader compilation failed: %@", error);
            return;
        }
        
        // Pipeline 1: 2D Stretching Triangle
        MTLRenderPipelineDescriptor *pipeDesc2D = [[MTLRenderPipelineDescriptor alloc] init];
        pipeDesc2D.vertexFunction = [library newFunctionWithName:@"vertexShader2D"];
        pipeDesc2D.fragmentFunction = [library newFunctionWithName:@"fragmentShader"];
        pipeDesc2D.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        renderer->pipelineState2D = [renderer->device newRenderPipelineStateWithDescriptor:pipeDesc2D error:&error];
        
        // Pipeline 2: 3D Interactive Prism/Pyramid
        MTLVertexDescriptor *vDesc3D = [MTLVertexDescriptor vertexDescriptor];
        vDesc3D.attributes[0].format = MTLVertexFormatFloat3;
        vDesc3D.attributes[0].offset = offsetof(Vertex3D, position);
        vDesc3D.attributes[0].bufferIndex = 0;
        vDesc3D.attributes[1].format = MTLVertexFormatFloat4;
        vDesc3D.attributes[1].offset = offsetof(Vertex3D, color);
        vDesc3D.attributes[1].bufferIndex = 0;
        vDesc3D.layouts[0].stride = sizeof(Vertex3D);
        
        MTLRenderPipelineDescriptor *pipeDesc3D = [[MTLRenderPipelineDescriptor alloc] init];
        pipeDesc3D.vertexFunction = [library newFunctionWithName:@"vertexShader3D"];
        pipeDesc3D.fragmentFunction = [library newFunctionWithName:@"fragmentShader"];
        pipeDesc3D.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pipeDesc3D.vertexDescriptor = vDesc3D;
        renderer->pipelineState3D = [renderer->device newRenderPipelineStateWithDescriptor:pipeDesc3D error:&error];
        
        // Generate 3D Geometry Data (A clean 3D triangular prism)
        Vertex3D geometry[] = {
            // Front Face triangle
            {{ 0.0f,  0.5f, -0.5f}, {1, 0, 0, 1}}, {{-0.5f, -0.5f, -0.5f}, {0, 1, 0, 1}}, {{ 0.5f, -0.5f, -0.5f}, {0, 0, 1, 1}},
            // Back Face triangle
            {{ 0.0f,  0.5f,  0.5f}, {1, 1, 0, 1}}, {{ 0.5f, -0.5f,  0.5f}, {0, 1, 1, 1}}, {{-0.5f, -0.5f,  0.5f}, {1, 0, 1, 1}},
            // Side Panel 1
            {{ 0.0f,  0.5f, -0.5f}, {1, 0, 0, 1}}, {{ 0.5f, -0.5f, -0.5f}, {0, 0, 1, 1}}, {{ 0.0f,  0.5f,  0.5f}, {1, 1, 0, 1}},
            {{ 0.5f, -0.5f, -0.5f}, {0, 0, 1, 1}}, {{ 0.5f, -0.5f,  0.5f}, {0, 1, 1, 1}}, {{ 0.0f,  0.5f,  0.5f}, {1, 1, 0, 1}},
            // Side Panel 2
            {{ 0.0f,  0.5f,  0.5f}, {1, 1, 0, 1}}, {{ -0.5f, -0.5f, 0.5f}, {1, 0, 1, 1}}, {{ 0.0f,  0.5f, -0.5f}, {1, 0, 0, 1}},
            {{-0.5f, -0.5f,  0.5f}, {1, 0, 1, 1}}, {{ -0.5f, -0.5f,-0.5f}, {0, 1, 0, 1}}, {{ 0.0f,  0.5f, -0.5f}, {1, 0, 0, 1}},
            // Bottom Panel
            {{-0.5f, -0.5f, -0.5f}, {0, 1, 0, 1}}, {{-0.5f, -0.5f,  0.5f}, {1, 0, 1, 1}}, {{ 0.5f, -0.5f, -0.5f}, {0, 0, 1, 1}},
            {{ 0.5f, -0.5f, -0.5f}, {0, 0, 1, 1}}, {{-0.5f, -0.5f,  0.5f}, {1, 0, 1, 1}}, {{ 0.5f, -0.5f,  0.5f}, {0, 1, 1, 1}}
        };
        renderer->vertexBuffer3D = [renderer->device newBufferWithBytes:geometry length:sizeof(geometry) options:MTLResourceStorageModeShared];
    });
    
    return renderer;
}

__attribute__((visibility("default")))
void update_renderer_bounds(void* rendererPtr, double x, double y, double width, double height, int clipMode) {
    if (!rendererPtr) return;
    MetalRenderer *renderer = (MetalRenderer*)rendererPtr;
    execute_on_main_thread(^{
        NSRect parentFrame = [renderer->parentWindow contentRectForFrameRect:renderer->parentWindow.frame];
        double cocoaX = parentFrame.origin.x + x;
        double cocoaY = parentFrame.origin.y + parentFrame.size.height - (y + height);
        
        [renderer->childWindow setFrame:NSMakeRect(cocoaX, cocoaY, width, height) display:YES];
        renderer->metalLayer.frame = renderer->metalView.bounds;
        
        if (clipMode == 1) {
            renderer->metalLayer.cornerRadius = 0.0;
            renderer->metalLayer.masksToBounds = NO;
            CAShapeLayer *maskLayer = [CAShapeLayer layer];
            CGPathRef path = CGPathCreateWithEllipseInRect(renderer->metalLayer.bounds, NULL);
            maskLayer.path = path;
            renderer->metalLayer.mask = maskLayer;
            CGPathRelease(path);
        } else {
            renderer->metalLayer.mask = nil;
            renderer->metalLayer.cornerRadius = 12.0; 
            renderer->metalLayer.masksToBounds = YES;
            renderer->metalLayer.maskedCorners = kCALayerMaxXMinYCorner;
        }
    });
}

__attribute__((visibility("default")))
void set_render_mode(void* rendererPtr, int mode) {
    if (rendererPtr) ((MetalRenderer*)rendererPtr)->renderMode = mode;
}

__attribute__((visibility("default")))
void update_rotation(void* rendererPtr, float deltaX, float deltaY) {
    if (!rendererPtr) return;
    MetalRenderer *renderer = (MetalRenderer*)rendererPtr;
    renderer->rotationY += deltaX * 0.01f; // Horizontal drag rotates around Y axis
    renderer->rotationX += deltaY * 0.01f; // Vertical drag rotates around X axis
}

__attribute__((visibility("default")))
void set_renderer_alpha(void* rendererPtr, float alpha) {
    if (rendererPtr) ((MetalRenderer*)rendererPtr)->globalAlpha = alpha;
}

__attribute__((visibility("default")))
void render_frame(void* rendererPtr) {
    if (!rendererPtr) return;
    MetalRenderer *renderer = (MetalRenderer*)rendererPtr;
    
    id<CAMetalDrawable> drawable = [renderer->metalLayer nextDrawable];
    if (!drawable) return;
    
    renderer->animationPhase += 0.02f;
    float redPulse = 0.15f + (sin(renderer->animationPhase) * 0.05f);
    float bluePulse = 0.25f + (cos(renderer->animationPhase) * 0.05f);
    
    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
    passDesc.colorAttachments[0].texture = drawable.texture;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(redPulse, 0.1, bluePulse, renderer->globalAlpha);
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    id<MTLCommandBuffer> commandBuffer = [renderer->commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDesc];
    
    if (renderer->renderMode == 1) {
        // --- 3D INTERACTIVE PRISM DRAW ---
        [encoder setRenderPipelineState:renderer->pipelineState3D];
        [encoder setVertexBuffer:renderer->vertexBuffer3D offset:0 atIndex:0];
        
        // Math matrices for Model-View-Projection
        simd_float4x4 modelMatrix = matrix_rotation(renderer->rotationX, renderer->rotationY);
        
        // Pull context aspect ratio dynamically
        float aspect = 1.0f;
        if (renderer->metalLayer.bounds.size.height > 0) {
            aspect = renderer->metalLayer.bounds.size.width / renderer->metalLayer.bounds.size.height;
        }
        
        simd_float4x4 projectionMatrix = matrix_perspective(60.0f * (M_PI / 180.0f), aspect, 0.1f, 10.0f);
        
        // Position camera back slightly along Z axis
        simd_float4x4 viewMatrix = matrix_identity();
        viewMatrix.columns[3].z = -2.0f; 
        
        // Combine them: MVP = Projection * View * Model
        simd_float4x4 mvp = simd_mul(projectionMatrix, simd_mul(viewMatrix, modelMatrix));
        
        // Load uniforms into the shader pipeline
        [encoder setVertexBytes:&mvp length:sizeof(mvp) atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:24];
    } else {
        // --- 2D STRETCHING TRIANGLE DRAW ---
        [encoder setRenderPipelineState:renderer->pipelineState2D];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}