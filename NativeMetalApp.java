///usr/bin/env jbang "$0" "$@" ; exit $?
//DEPS org.openjfx:javafx-controls:26.0.1:mac-aarch64

//RUNTIME_OPTIONS --enable-native-access=ALL-UNNAMED,javafx.graphics
//RUNTIME_OPTIONS --add-opens javafx.graphics/com.sun.glass.ui=ALL-UNNAMED

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
package com.prototype;

import javafx.animation.AnimationTimer;
import javafx.application.Application;
import javafx.application.Platform;
import javafx.geometry.Bounds;
import javafx.scene.Scene;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.control.CheckBox;
import javafx.scene.control.ComboBox;
import javafx.scene.control.Slider;
import javafx.scene.control.SplitPane;
import javafx.scene.layout.Pane;
import javafx.scene.layout.VBox;
import javafx.scene.text.Text;
import javafx.stage.Stage;

import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;
import java.nio.file.Paths;

public class NativeMetalApp extends Application {

    private MemorySegment nativeRendererContext = MemorySegment.NULL;
    private MethodHandle initMetalFunc;
    private MethodHandle updateBoundsFunc;
    private MethodHandle renderFrameFunc;
    private MethodHandle setAlphaFunc;
    private MethodHandle setRenderModeFunc;
    private MethodHandle updateRotationFunc;

    private Pane rightMetalPane;
    // Variables to keep track of drag baselines
    private double lastMouseX;
    private double lastMouseY;


    @Override
    public void init() throws Exception {
        String dylibPath = Paths.get("librenderer.dylib").toAbsolutePath().toString();
        System.load(dylibPath);
        
        SymbolLookup lookup = SymbolLookup.libraryLookup(dylibPath, Arena.global());
        Linker linker = Linker.nativeLinker();

        initMetalFunc = linker.downcallHandle(
            lookup.find("init_metal_renderer").orElseThrow(),
            FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.ADDRESS)
        );

        updateBoundsFunc = linker.downcallHandle(
            lookup.find("update_renderer_bounds").orElseThrow(),
            FunctionDescriptor.ofVoid(
                ValueLayout.ADDRESS,    // renderer context pointer
                ValueLayout.JAVA_DOUBLE, // X
                ValueLayout.JAVA_DOUBLE, // Y
                ValueLayout.JAVA_DOUBLE, // Width
                ValueLayout.JAVA_DOUBLE, // Height
                ValueLayout.JAVA_INT     // clipMode flag (0 = Normal Rounded, 1 = Irregular Ellipse)
            )
        );

        renderFrameFunc = linker.downcallHandle(
            lookup.find("render_frame").orElseThrow(),
            FunctionDescriptor.ofVoid(ValueLayout.ADDRESS)
        );

        // 1. Declare your new MethodHandle alongside your bounds handle
        setAlphaFunc = linker.downcallHandle(
            lookup.find("set_renderer_alpha").orElseThrow(), // your lookup method here
                FunctionDescriptor.ofVoid(
                    ValueLayout.ADDRESS,   // renderer context pointer
                    ValueLayout.JAVA_FLOAT // alpha value
                )
            );

        // 1. Bind your new native configuration functions
        setRenderModeFunc = linker.downcallHandle(
            lookup.find("set_render_mode").orElseThrow(),
            FunctionDescriptor.ofVoid(ValueLayout.ADDRESS, ValueLayout.JAVA_INT)
        );

        updateRotationFunc = linker.downcallHandle(
            lookup.find("update_rotation").orElseThrow(),
            FunctionDescriptor.ofVoid(ValueLayout.ADDRESS, ValueLayout.JAVA_FLOAT, ValueLayout.JAVA_FLOAT)
        );   
    }

    @Override
    public void start(Stage primaryStage) {
        primaryStage.setTitle("JavaFX 25 FFM Metal Overlay");

        VBox leftPane = new VBox(15);
        leftPane.setStyle("-fx-padding: 20px;");
        leftPane.setMinWidth(250);
        Text statusText = new Text("Native Surface Status: Unbound");
        Button triggerBtn = new Button("Interact");
        CheckBox clipToggle = new CheckBox("Enable Irregular Clip Path");
        clipToggle.setOnAction(e -> {
            activeClipMode = clipToggle.isSelected() ? 1 : 0;
            try {
                syncNativeOverlayBounds();
            } catch (Throwable ex) {
                ex.printStackTrace();
            }
        });
        // 2. Build and style the JavaFX Slider control
        Slider opacitySlider = new Slider(0.0, 1.0, 0.4); // Min 0.0, Max 1.0, Default 0.4
        opacitySlider.setShowTickMarks(true);
        opacitySlider.setShowTickLabels(true);
        opacitySlider.setMajorTickUnit(0.25);
        opacitySlider.setBlockIncrement(0.05);

        Label opacityLabel = new Label("Metal Layer Opacity: 40%");
        opacityLabel.setStyle("-fx-font-weight: bold;");

        // 3. Add a reactive listener to fire native pipeline adjustments instantly
        opacitySlider.valueProperty().addListener((observable, oldValue, newValue) -> {
            float targetAlpha = newValue.floatValue();
            opacityLabel.setText(String.format("Metal Layer Opacity: %d%%", (int)(targetAlpha * 100)));
            
            try {
                // Direct, lock-free invocation to the native state layer
                setAlphaFunc.invokeExact(nativeRendererContext, targetAlpha);
            } catch (Throwable t) {
                t.printStackTrace();
            }
        });

        // Select 2D or 3D display mode
        ComboBox<String> viewModeCombo = new ComboBox<>();
        viewModeCombo.getItems().addAll("2D Stretching Triangle", "3D Interactive Prism");
        viewModeCombo.getSelectionModel().selectFirst();

        viewModeCombo.setOnAction(e -> {
            int selectedMode = viewModeCombo.getSelectionModel().getSelectedIndex();
            try {
                setRenderModeFunc.invokeExact(nativeRendererContext, selectedMode);
            } catch (Throwable t) {
                t.printStackTrace();
            }
        });

        leftPane.getChildren().addAll(statusText, triggerBtn, clipToggle, opacitySlider, viewModeCombo);

        // Right view placeholder pane instead of a SwingNode
        rightMetalPane = new Pane();

        // 1. Give the pane a loud, high-contrast gradient background via CSS
        rightMetalPane.setStyle("-fx-background-color: linear-gradient(to bottom right, #ff7e5f, #feb47b, #2f80ed);");

        // 2. Drop a high-contrast Label or Grid inside it to verify sharpness/clipping
        Label testPatternLabel = new Label("JAVAFX CONTENT UNDERNEATH\nGPU METAL LAYER ACTIVE");
        testPatternLabel.setStyle("-fx-font-size: 20px; -fx-text-fill: white; -fx-font-weight: bold; -fx-alignment: center;");
        testPatternLabel.setWrapText(true);

        // Center it up inside the pane
        rightMetalPane.getChildren().add(testPatternLabel);

        // 2d or 3d and rotate shape features
        // 2. Attach mouse event handlers directly to your JavaFX Right Pane container
        rightMetalPane.setOnMousePressed(e -> {
            lastMouseX = e.getX();
            lastMouseY = e.getY();
        });

        rightMetalPane.setOnMouseDragged(e -> {
            float deltaX = (float) (e.getX() - lastMouseX);
            float deltaY = (float) (e.getY() - lastMouseY);
            
            lastMouseX = e.getX();
            lastMouseY = e.getY();
            
            try {
                // Fire the mouse displacement vectors straight down to the GPU matrix encoder
                updateRotationFunc.invokeExact(nativeRendererContext, deltaX, deltaY);
            } catch (Throwable t) {
                t.printStackTrace();
            }
        }); 

        SplitPane root = new SplitPane();
        root.getItems().addAll(leftPane, rightMetalPane);

        primaryStage.setScene(new Scene(root, 1024, 768));
        primaryStage.show();

        Platform.runLater(() -> {
            root.setDividerPositions(0.3f);
            long nsWindowHandle = getGlassWindowHandle();
            if (nsWindowHandle != 0) {
                try {
                    nativeRendererContext = (MemorySegment) initMetalFunc.invokeExact(MemorySegment.ofAddress(nsWindowHandle));
                    statusText.setText("Metal Overlay Attached!");
                } catch (Throwable t) {
                    t.printStackTrace();
                }
            }
        });

        // Loop handles layout syncing and animation on the frame pulse
        new AnimationTimer() {
            @Override
            public void handle(long now) {
                if (nativeRendererContext != MemorySegment.NULL) {
                    try {
                        syncNativeOverlayBounds();
                        renderFrameFunc.invokeExact(nativeRendererContext);
                    } catch (Throwable t) {
                        t.printStackTrace();
                    }
                }
            }
        }.start();
    }

    // You can tie this integer to a JavaFX CheckBox or ToggleButton value
    private int activeClipMode = 0; 

    private void syncNativeOverlayBounds() throws Throwable {
        Scene scene = rightMetalPane.getScene();
        if (scene == null) return;

        Bounds bounds = rightMetalPane.localToScene(rightMetalPane.getBoundsInLocal());
        
        double fxX = bounds.getMinX();
        double fxY = bounds.getMinY();
        double width = bounds.getWidth();
        double height = bounds.getHeight();

        // Pass the structural shape layout selection straight to the native component
        updateBoundsFunc.invokeExact(nativeRendererContext, fxX, fxY, width, height, activeClipMode);
    }

    private long getGlassWindowHandle() {
        try {
            Class<?> windowClass = Class.forName("com.sun.glass.ui.Window");
            java.lang.reflect.Method getWindows = windowClass.getMethod("getWindows");
            java.util.List<?> windows = (java.util.List<?>) getWindows.invoke(null);
            
            if (!windows.isEmpty()) {
                Object mainGlassWindow = windows.get(0);
                java.lang.reflect.Method getNativeWindow = mainGlassWindow.getClass().getMethod("getNativeWindow");
                return (long) getNativeWindow.invoke(mainGlassWindow);
            }
        } catch (Exception e) {
            System.err.println("Could not resolve native Glass handle.");
            e.printStackTrace();
        }
        return 0;
    }

    public static void main(String[] args) {
        launch(args);
    }
}