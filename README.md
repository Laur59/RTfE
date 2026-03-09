# RISC-V Toolchain

Welcome to the RISC-V Toolchain project!

This repository contains the source code for the RISC-V Toolchain
project, a fork of the LLVM project containing build scripts and
auxiliary material for building LLVM based toolchains targeting
RISC-V for bare-metal environments.

## Goal

This project aims to provide an LLVM based platform containing
the necessary libraries and tools for building C and C++ toolchains
for bare-metal: [RISC-V Toolchain for Embedded](https://github.com/Laur59/RTfE/blob/riscv-software/riscv-software/embedded/README.md)

## Introduction

This project provides a RISC‑V embedded toolchain inspired by the the methodology used in ARM’s embedded toolchain on GitHub ([1][1]). It specifically targets 32‑bit and 64‑bit RISC‑V cores, and is designed for **bare-metal** (no OS) systems only—i.e. embedded Linux for RISC-V is **not** supported.

To keep the toolchain simpler and focused, it uses **newlib** exclusively as the C standard library. Unlike some other toolchains which allow alternatives such as **picolibc** or LLVM libc, this repository does **not** include those options. The toolchain is a **multilib** design, supporting multiple RISC-V variants via a single build infrastructure.

The source code is a hard fork of LLVM (the official `llvm-project` repository [LLVM project](https://github.com/llvm/llvm-project)), and it is periodically kept in sync via upstream merges. A new top-level folder, `riscv-software`, is added at the root; this directory contains all of the additional code, scripts, and configuration files needed to build the **RISC-V Toolchain for Embedded (RTfE)**.

This toolchain is intended to run on **Linux** or **macOS**. **Windows is not supported** at this time.

### Prerequisites

Before building the toolchain, ensure the following dependencies are installed:

### Required Tools

* **Clang** – C/C++ compiler from LLVM (version 15 or higher recommended)
* **CMake** – Build system generator (version 3.15 or higher)
* **Ninja** – Fast build system
* **Git** – To clone and update repositories

### Platform Requirements

* **macOS** (or **Linux** (Ubuntu, Debian, Fedora, etc.))
* Sufficient disk space (~5–10 GB) for building the toolchain
* Internet access for downloading dependencies and upstream sources

Install these tools using your platform's package manager. For example, on Ubuntu:

```bash
sudo apt update
sudo apt install clang cmake ninja-build git
```

Or on macOS (with Homebrew):

```bash
brew install cmake ninja git
```

### Building the Toolchain

After cloning the repository, the recommended steps to build the toolchain are:

```bash
cmake -S $RTfE/riscv-software/embedded -B $BUILD
cmake --build $BUILD
cmake --install $BUILD
```

Replace `$RTfE` with the path to the root of this repository, and `$BUILD` with your preferred build directory.

### Usage Example

Once installed, the toolchain can be used to compile bare-metal RISC-V programs. Here's a simple example using `clang`:

```bash
riscv32-unknown-elf-clang -march=rv32imac -mabi=ilp32 \
  -nostdlib -T linker_script.ld -o program.elf main.c
```

* `-march` and `-mabi` specify the target architecture and ABI.
* `-nostdlib` disables linking against standard libraries (as is typical in bare-metal).
* `-T` provides a custom linker script.
* `main.c` is your application source file.

You can also use the resulting toolchain in CMake-based embedded projects by setting appropriate toolchain and compiler options.

---

## Project Structure

Below is a high-level sketch of the repository structure and the roles of key directories (as observed from the RTfE repository) ([GitHub][2]). (You may want to refine or expand this to match future reorganizations.)

```
/
├── riscv-software/           # Root for the embedded‑toolchain specific files
│   ├── embedded/             # Entry point for building the embedded toolchain
│   │   ├── riscv-multilib
│   │   ├── riscv-runtimes
│   │   ├── cmake
│   │   └── docs
│   ├── ...                    # Subdirectories: scripts, configuration, patches, etc.
├── llvm/                      # Upstream LLVM fork (passes through standard LLVM subprojects)
├── clang/                     # Clang front end (as part of upstream fork)
├── compiler-rt/               # Compiler runtime support (e.g. builtins, sanitizer stubs, etc.)
├── libc/                      # (Likely hosts newlib or bindings / integration code)
├── libcxx/ / libcxxabi/       # (Present but not currently enabled for embedded)
├── lld/                       # Linker component
├── libunwind/                 # (If used or stubbed)
├── other LLVM subprojects ... # (e.g. MLIR, Polly, etc.)
├── third-party/               # External dependencies or vendored components
├── .github/ / CI / .ci/       # CI and workflow configuration
├── README.md  
├── CONTRIBUTING.md  
├── LICENSE.TXT  
└── other metadata files  
```

**Major directories & their responsibilities:**

* **`riscv-software/embedded/`**: This is the primary “front door” for building the embedded toolchain. It contains the CMake entrypoint, toolchain configuration files, patch application scripts, and logic to drive multi-target builds (different RISC-V ISA variants, ABIs, etc.).

* **LLVM subprojects (e.g. `llvm/`, `clang/`, `lld/`)**: These directories mirror standard LLVM structure; your fork likely retains compatibility with upstream builds, integrating the additional RTfE patches.

* **`libc/`, `libcxx/`, `libcxxabi/`**: These directories hold library code or interface glue; presently, only `newlib` (in `libc/`) is active; the others are present but disabled or commented out.

* **`third-party/`**: This hosts external dependencies or vendored modules that cannot easily be fetched or built at runtime.

* **CI & `.github/`**: Build workflows, checks, and automation for upstream merges, patch application, and testing.

You might consider adding a **`docs/`** directory in the future for API or design documentation, or a **`samples/`** directory for example projects.

---

## Toolchain Customization

This section describes how one might adapt or extend the toolchain configuration to meet different project needs: enabling new variants, enabling or re-enabling C++ support, customizing ABI choices, etc.

### Enabling C++ Support

Although the current release does not ship with C++ support, the infrastructure is present but commented out. To re-enable or incorporate C++ libraries:

1. **Uncomment or reintroduce the relevant build options and flags** in `riscv-software/embedded/CMakeLists.txt` (or related toolchain config files).
2. Add or enable building of **libc++**, **libc++abi**, and possibly **libunwind** or stub support.
3. Ensure that the C++ runtime and standard library code is compatible with the bare-metal constraints (e.g. no reliance on OS syscalls or dynamic memory unless handled explicitly).
4. Adjust linker scripts or startup stubs to include C++ initialization (`_init`, `__cxa_atexit`, static constructors, etc.).

### Multi‑ABI / Multi‑ISA Support

Since this is a multilib toolchain, customization may involve:

* Defining new **ISA variants** (e.g. adding support for “E” subset or custom extensions).
* Customizing **ABI options** (e.g. adding alternative ABIs if desired).
* Controlling which combinations of ISA + ABI are built (to limit build time or binary size).

These customizations typically involve editing the CMake configuration (toolchain definitions, target lists, variant tables) and possibly patching parts of LLVM/Clang to accept or optimize for the custom variants.

### Patching and Upstream Integration

Because RTfE is a hard fork of LLVM, careful management of upstream merges and custom patches is essential:

* Maintain a **patch set** that describes which modifications are applied on top of upstream LLVM.
* Use a structured patch or overlay system rather than ad-hoc commits, so that merges from upstream can be applied cleanly.
* Prefer to upstream generic fixes or enhancements back to LLVM when possible, to reduce divergence effort.
* Clearly document any divergences, especially in code generation, target-specific optimizations, or ABI behavior.

### Toolchain Invocation and Presets

You may wish to add **preset driver scripts or wrapper stubs** to simplify use:

* A wrapper `riscv-embedded-clang` that hides flags (ISA, ABI, sysroot, linker script, etc.).
* Preset JSON or TOML files to define target configurations (e.g. `rv32imac-ilp32`, `rv64gc-lp64d`).
* Addition of convenience CMake toolchain files for downstream embedded projects to consume directly.

### Custom Extensions, Intrinsics & Instructions

If your target RISC-V cores implement **custom instructions** or **CSRs**, you may adapt the toolchain:

* Add entries in `riscv-opcodes` or equivalent tables to support new instructions.
* Introduce LLVM intrinsics or backend support to generate or lower these custom instructions.
* Provide header files for inline assembly or intrinsics.
* Ensure the linker, assembler, and disassembler tools recognize and support these extensions.

---

## Contributing

To help you and future contributors participate smoothly, here are guidelines and best practices (some inherited from LLVM conventions and GitHub workflows):

* **Follow the upstream-style patch workflow**: develop changes as discrete patches or topics, enabling clean merges from upstream LLVM.
* **Small, focused commits** are preferable to large monolithic changes. Each commit should have a clear purpose.
* **Write tests** for new features, especially corner cases or multi‑variant configurations. Use CI to verify correctness across variants.
* **Document changes** in code, README, or a `CHANGELOG.md` to explain the rationale, especially for divergence from upstream behavior.
* **Review upstream LLVM style and conventions**, especially for naming, code layout, and pass infrastructure.
* **Coordinate merges**: when upstream LLVM introduces changes that conflict with RTfE patches, prepare rebase or merge resolutions early.
* **Issue tracking**: use the repository Issues or Discussions to propose enhancements, report bugs, or solicit review.
* **Citations and attribution**: if incorporating upstream patches or ideas, respect licensing and attribution requirements.

---

[1]: https://github.com/arm/arm-toolchain.git	"Arm Toolchain"
[2]: https://github.com/Laur59/RTfE.git "GitHub - Laur59/RTfE: RISC-V Toolchain for Embedded"
