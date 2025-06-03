Current Tasks in progress: 
1. Fix ocean mesh and terrain mesh clipping and z-fighting.
2.  make the wave cascades start point editable. (currently only produces cascades that start at the north and south poles only. 
3. procedural noise biome textures. no image textures unless i make then with noise from fastnoiselite
4. erosion simulation on mountain terrain.
5. integrate werner dune simulation to appear in desert landscapes
6. colliders




List of Cited Sources and Inspirations for Ocean Water System

***Still updating and not final***

Everything was found openly on the internet. 





**Primary Ocean Wave Implementation
**

**GodotOceanWaves Repository**

Original: https://github.com/2Retr0/GodotOceanWaves
Fork/Adaptation: https://github.com/krautdev/GodotOceanWaves
Tutorial Video: https://www.youtube.com/watch?v=waVAmgsC_4Q&t=14s



**Ocean Rendering and Wave Theory**

**"Wakes, Explosions and Lighting: Interactive Water Simulation in Atlas" (GDC 2019)**

Source: https://gpuopen.com/gdc-presentations/2019/gdc-2019-agtd6-interactive-water-simulation-in-atlas.pdf




**Jerry Tessendorf** - "Simulating Ocean Water"

The foundational paper for FFT ocean simulation
Referenced in spectrum generation and modulation




**Christopher J. Horvath** - "Empirical Directional Wave Spectra for Computer Graphics"

Source for Hasselmann directional spreading implementation
Used in spectrum_compute.glsl




**JONSWAP Spectrum Documentation
**
Source: https://wikiwaves.org/Ocean-Wave_Spectra#JONSWAP_Spectrum
Used for wave spectrum calculations in wave_generator.gd



**GPU and Rendering Techniques**

**"Fast Third-Order Texture Filtering" - GPU Gems 2, Chapter 20**

Source: https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-20-fast-third-order-texture-filtering
Used for bicubic B-spline filtering in planet_water.gdshader


**Godot Engine Source Code - GGX Distribution**

Source: https://github.com/godotengine/godot/blob/7b56111c297f24304eb911fe75082d8cdc3d4141/drivers/gles3/shaders/scene.glsl#L995
Referenced for GGX distribution implementation


**NVIDIA Blog -** "Efficient Matrix Transpose in CUDA CC"

Source: https://developer.nvidia.com/blog/efficient-matrix-transpose-cuda-cc/
Used for transpose.glsl implementation



**FFT Implementation

Stockham FFT Algorithm**

Source: http://wwwa.pikara.ne.jp/okojisan/otfft-en/stockham3.html
Referenced in fft_compute.glsl


**Robert Matusiak -** "Implementing Fast Fourier Transform Algorithms of Real-Valued Sequences With the TMS320 DSP Platform"

Referenced in spectrum_modulate.glsl for FFT packing techniques



**Utility Functions**

**Shadertoy -** "Hash without Sine" by Dave_Hoskins

Source: https://www.shadertoy.com/view/Xt3cDn
Used for hash functions in sea_spray_particle.gdshader and spectrum_compute.glsl


**Inigo Quilez -** "Useful Little Functions"

Source: https://iquilezles.org/articles/functions/
Used for exp_impulse function in sea_spray_particle.gdshader



**Additional Inspirations

Sea of Thieves Water Rendering**

Mentioned as inspiration for subsurface scattering approach
Influenced the visual style choices



**Implementation Framework

Godot Engine Documentation**

RenderingDevice API
Compute shader implementation
Global shader parameters system



**Academic and Industry Papers (General References)**

Various oceanography papers on wave spectra
Real-time rendering techniques for water
GPU-based FFT implementations
Spherical ocean rendering for planets

These sources collectively provided the theoretical foundation, implementation details, and optimization techniques that made this sophisticated ocean water system possible. The combination of academic research, industry presentations, open-source code, and creative adaptations resulted in a comprehensive solution for both flat and spherical ocean rendering with realistic wave physics.
