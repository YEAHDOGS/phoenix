import { dedup, flatten, instance, join, palette, prune, resample, simplify, sparse, textureCompress, weld, quantize } from '@gltf-transform/functions';
import { MeshoptSimplifier } from 'meshoptimizer';

// Run the entire optimization cycle 3 times sequentially
for (let i = 0; i < 3; i++) {
    await document.transform(
        // 1. CLEAN & REPAIR
        weld(),

        // 2. SCENE GRAPH OPTIMIZATION
        dedup(),
        instance({ min: 5 }),
        palette({ min: 5 }),
        flatten(),
        join(),
		weld(),

        // 3. SAFE GEOMETRY SIMPLIFICATION
        simplify({
            simplifier: MeshoptSimplifier,
            error: 0.0001, 
            ratio: 0.0,    
            lockBorder: true,
        }),

        // 4. BIT-DEPTH REDUCTION
        quantize({
            quantizePosition: 14, 
            quantizeTexcoord: 12, 
            quantizeColor: 8
        }),

        // 5. TIMELINE & STORAGE EXTRACTION
        resample(),
        sparse({ ratio: 0.2 }),

        // 6. TEXTURE COMPRESSION
        textureCompress({ 
            targetFormat: 'webp', 
            resize: [1024, 1024] 
        }),

        // 7. HOUSE CLEANING (Flushes out newly created empty nodes/buffers)
        prune(),
    );
}