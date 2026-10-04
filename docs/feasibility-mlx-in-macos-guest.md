# Can a macOS guest run MLX on the GPU?

Researched 2026-10-03. No VM was run; everything below is from sources, read on
that date, plus MLX's source code. Measurements are other people's, on other hardware.

## Answer

Yes, MLX runs on the host GPU from a macOS guest under Virtualization.framework, through Apple's
paravirtualized graphics device. How close to host speed is not established: the one published
MLX measurement in a guest has no bare-metal baseline beside it. A related llama.cpp measurement
on the same setup reached 72–99% of host speed once the guest's under-reported capabilities were
worked around.

## Evidence

1. Apple, WWDC22 session 10002, "Create macOS or Linux virtual machines",
   https://developer.apple.com/videos/play/wwdc2022/10002/ (transcript):
   "We have built a graphic device that exposes the GPU capabilities to the virtual Mac. This
   means you can run Metal in the virtual machine, and get great graphics performance in macOS."
   The configuration is `VZMacGraphicsDeviceConfiguration` (macOS 12+). Apple speaks of graphics;
   it says nothing about compute.

2. Cua, "GPU passthrough in macOS VMs", 2026-08-11,
   https://github.com/trycua/cua/blob/main/blog/gpu-passthrough-macos-vms.md
   (raw logs linked from it under `evidence/lume-metal-capability-shim/`). Host M1 Ultra 48-core
   GPU, macOS 26.6.1; guest macOS 26.5.2, 8 vCPU, 16 GiB, in Lume 0.5.1.
   - "In our stock Tahoe VM, the paravirtualized device reported roughly an Apple 5-era family,
     32 KB of maximum threadgroup memory, and SIMD-group matrix support as unavailable."
   - MLX 0.32.0 / MLX-LM 0.31.3, Llama-3.2-3B-Instruct-4bit, in the stock guest: prompt 512
     tokens 1,656.55 tok/s, generation 128 tokens 172.09 tok/s. Their capability shim changed
     nothing (1.005×, 0.993×): "Performance stayed flat because MLX-LM was already fast in the
     stock VM". No bare-metal MLX number is given.
   - llama.cpp, which does choose kernels by the reported family: stock guest at 4–9% of host;
     with the shim, TinyLlama 98.25% (prompt) and 72.06% (generation) of host, Gemma 4 12B
     99.59% and 94.82%.
   - "advertising `MTLGPUFamilyMetal3` made MLX request a residency set unavailable through the
     paravirtualized device."
   - The shim needs a host preference
     (`com.apple.gpusw.ParavirtualizedGraphics ForceUnrestrictedDeviceFeatureLevel`) and
     `DYLD_INSERT_LIBRARIES` in the guest; they call it experimental and reliant on private
     behaviour.

3. JuliaGPU/Metal.jl PR #789, merged 2026-06-04, https://github.com/JuliaGPU/Metal.jl/pull/789:
   the "Apple Paravirtual device" in GitHub's macOS 14/15 runner VMs "supports Metal 3, but
   under-reports its capabilities via supportsFamily:, claiming to lack MTLGPUFamilyApple7/Metal3."
   GPU logging (`MTLLogState`) and residency sets were missing there.

4. MLX v0.32.0 source, read 2026-10-03:
   - `mlx/backend/metal/device.cpp` lines 585–600: MLX picks its tuning from
     `device->architecture()->name()` (or the env override `env::metal_gpu_arch()`), not from
     `supportsFamily:`, and ships a precompiled metallib. That is why the under-reported family
     doesn't slow MLX, where it does slow llama.cpp.
   - `mlx/backend/metal/resident.cpp` line 9: `if (!d->supportsFamily(MTL::GPUFamilyMetal3))`
     skips the residency set, so in a guest MLX runs without wiring its buffers resident.

## What isn't established, and needs a VM to settle

1. MLX guest speed as a fraction of host speed. My inference, labelled as such: since MLX ignores
   the reported family, it should land near the shimmed llama.cpp figures, but nobody has
   published the pair.
2. Training. Every published guest number is inference. Backward passes, optimizer steps, long
   runs and memory pressure in a guest are untested.
3. Recent chips such as M3 and M4. All measurements are M1 Ultra (Cua) or GitHub's runners.
4. Memory. Guest RAM is a fixed carve-out of host unified memory; how much of it the guest's GPU
   may use, and what losing residency sets costs, are unmeasured.
5. What the paravirtual device returns for `architecture()->name()`. If MLX can't parse it, it
   falls to default buffer sizing; the env var `MLX_METAL_GPU_ARCH` (`mlx/utils.h` line 206)
   overrides it.

## The measurement that would settle 1–5

Same MLX script, host and guest, same machine: a small transformer's training step
(forward + backward + AdamW) in tokens/s and step time, plus a matmul throughput probe, with
guest RAM set close to the host's free memory. Needs a restore image (~15–20 GB) and a VM disk
(≥ 40 GB), so a machine with room.
