// Load generator for thermal correlation probing. Runs a Metal compute loop for the given number of seconds.
// Touches no hardware keys.
import Foundation
import Metal

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "25") ?? 25
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { exit(1) }
let source = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *o [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float v = float(id);
    for (int i = 0; i < 4000; i++) { v = sin(v) * cos(v) + sqrt(abs(v) + 1.0); }
    o[id] = v;
}
"""
guard let library = try? device.makeLibrary(source: source, options: nil),
      let function = library.makeFunction(name: "burn"),
      let pipeline = try? device.makeComputePipelineState(function: function),
      let buffer = device.makeBuffer(length: 4 << 20, options: .storageModeShared) else { exit(1) }
let end = Date().addingTimeInterval(seconds)
while Date() < end {
    guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { exit(1) }
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: 1 << 20, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
}
