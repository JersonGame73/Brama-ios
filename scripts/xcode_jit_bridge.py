#!/usr/bin/env python3
"""
Brama — Xcode / LLDB iOS 26 TXM JIT Bridge for Madeira (Wine 9.0 ARM64EC + FEX-Emu)
===================================================================================
Automatically intercepts `jit26_prepare_region` and `jit26_detach` when running Brama
from Xcode (`Cmd + R`) on iOS / iPadOS 26+ devices with TXM (Trusted Execution Monitor).

Why this is required on iOS/iPadOS 26.5:
- XNU's TXM rejects self-mapped RX pages with `EXC_BAD_ACCESS (code=50 / KERN_CODESIGN_ERROR)`
  even when `CS_DEBUGGED` is active.
- Pages are only blessed by TXM when `debugserver` itself allocates the RX region (`_M<size>,rx`)
  and writes at least 1 byte into each 16KB (`0x4000`) page (`M<addr>,...`), which faults the
  physical page into `pmap` and triggers `debugserver`'s `mach_vm_protect(..., VM_PROT_READ | VM_PROT_EXECUTE)`.
- By writing 2 bytes (`0x69 0x69`) across each odd 16KB page boundary (`(2*k + 1)*0x4000 - 1`),
  each `WriteMemory` call faults and blesses TWO adjacent 16KB pages simultaneously (4,096 calls
  for a 128 MB JIT pool).
"""

import time
import lldb

_handled_stops = set()
_configured_pids = set()


def _configure_process_for_wine(debugger, process):
    """Configure debugserver and LLDB so Wine/FEX signals and Mach exceptions pass through."""
    if not process or not process.IsValid():
        return
    pid = process.GetProcessID()
    if pid in _configured_pids:
        return
    _configured_pids.add(pid)

    ci = debugger.GetCommandInterpreter()
    res = lldb.SBCommandReturnObject()

    # Tell debugserver to pass EXC_BAD_ACCESS and EXC_BAD_INSTRUCTION directly to Wine/FEX's
    # in-process Mach exception handler instead of pausing Xcode on every guard page fault.
    ci.HandleCommand(
        "process plugin packet send QSetIgnoredExceptions:EXC_BAD_ACCESS;EXC_BAD_INSTRUCTION",
        res,
    )
    ci.HandleCommand(
        "process plugin packet send QPassSignals:1;2;3;4;6;7;8;9;a;b;c;d;e;f;10;11;12;13;14;15;16;17;18;19;1a;1b;1c;1d;1e;1f",
        res,
    )

    for sig in ("SIGUSR1", "SIGUSR2", "SIGSEGV", "SIGBUS", "SIGILL", "SIGFPE", "SIGPIPE"):
        ci.HandleCommand(f"process handle {sig} -n false -p true -s false", res)


def _advance_pc_past_brk(frame):
    """Advance PC past `brk #0xf00d` inside `jit26_prepare_region` or `jit26_detach`."""
    pc_reg = frame.FindRegister("pc")
    lr_reg = frame.FindRegister("lr")
    pc = pc_reg.GetValueAsUnsigned(0)
    lr = lr_reg.GetValueAsUnsigned(0)

    sym = frame.GetSymbol()
    if sym and sym.IsValid():
        target = frame.GetThread().GetProcess().GetTarget()
        func_start = sym.GetStartAddress().GetLoadAddress(target)
        func_name = sym.GetName() or ""
        if "jit26_prepare_region" in func_name and func_start != lldb.LLDB_INVALID_ADDRESS:
            # _jit26_prepare_region layout in libmadeira.dylib:
            #   +0x00: sub sp, sp, #0x20
            #   ...
            #   +0x28: brk #0xf00d
            #   +0x2c: str x0, [sp, #0x8]
            #   +0x30: ldr x0, [sp, #0x8]
            #   +0x34: add sp, sp, #0x20
            #   +0x38: ret
            if pc == func_start:
                # Stopped at +0x00 before `sub sp, sp, #0x20`: return directly via lr
                pc_reg.SetValueFromCString(f"0x{lr:x}")
                return
            else:
                # Stopped after `sub sp, sp, #0x20`: jump to +0x2c so `add sp, sp, #0x20; ret` runs
                pc_reg.SetValueFromCString(f"0x{func_start + 0x2c:x}")
                return

    # Default for `jit26_detach` (no stack frame) or unknown symbol: return via lr
    if lr != 0:
        pc_reg.SetValueFromCString(f"0x{lr:x}")
    else:
        pc_reg.SetValueFromCString(f"0x{pc + 4:x}")


def _prepare_txm_jit_pool(frame):
    """Allocate and TXM-bless the requested RX JIT pool in debugserver."""
    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()
    debugger = target.GetDebugger()

    _configure_process_for_wine(debugger, process)

    x0_reg = frame.FindRegister("x0")
    x1_reg = frame.FindRegister("x1")
    req_addr = x0_reg.GetValueAsUnsigned(0)
    req_size = x1_reg.GetValueAsUnsigned(0)

    if req_size == 0 or req_size > 0x40000000:
        req_size = 0x8000000  # Default: 128 MB

    size_mb = req_size // (1024 * 1024)
    print(
        f"[Brama-Xcode-JIT] Intercepted jit26_prepare_region(addr=0x{req_addr:x}, size=0x{req_size:x} [{size_mb} MB])"
    )

    err = lldb.SBError()
    rx_addr = process.AllocateMemory(
        req_size, lldb.ePermissionsReadable | lldb.ePermissionsExecutable, err
    )
    if not err.Success() or rx_addr == lldb.LLDB_INVALID_ADDRESS or rx_addr == 0:
        # Fallback to raw GDB remote `_M<size>,rx` packet if AllocateMemory failed
        ci = debugger.GetCommandInterpreter()
        res = lldb.SBCommandReturnObject()
        ci.HandleCommand(f"process plugin packet send _M{req_size:x},rx", res)
        out = res.GetOutput() or ""
        rx_addr = 0
        for line in out.splitlines():
            if "response:" in line:
                hex_str = line.split("response:", 1)[1].strip()
                try:
                    rx_addr = int(hex_str, 16)
                except ValueError:
                    rx_addr = 0

    if rx_addr == 0 or rx_addr == lldb.LLDB_INVALID_ADDRESS:
        print(f"[Brama-Xcode-JIT] ERROR: Failed to allocate RX region of {size_mb} MB: {err}")
        x0_reg.SetValueFromCString("0x0")
        _advance_pc_past_brk(frame)
        return False

    page_size = 0x4000  # 16 KB Apple Silicon page size
    num_pages = (req_size + page_size - 1) // page_size
    t0 = time.time()
    print(
        f"[Brama-Xcode-JIT] Allocated RX @ 0x{rx_addr:x} ({size_mb} MB, {num_pages} pages). Blessing TXM pages..."
    )

    # Touch first page
    process.WriteMemory(rx_addr, b"\x69", err)

    # Write 2 bytes (0x69 0x69) across each odd 16KB page boundary:
    # Address = rx_addr + ((2*k + 1) * 0x4000) - 1
    # Byte 0 lands at the end of page (2*k), Byte 1 lands at the start of page (2*k + 1).
    # Each call faults and TXM-blesses TWO 16KB pages at once!
    pair_count = num_pages // 2
    two_bytes = b"\x69\x69"
    step_report = max(1, pair_count // 4)
    for k in range(pair_count):
        boundary = rx_addr + (((2 * k + 1) << 14) - 1)
        process.WriteMemory(boundary, two_bytes, err)
        if (k + 1) % step_report == 0:
            pct = int(((k + 1) * 100) / pair_count)
            print(f"[Brama-Xcode-JIT] Blessing TXM JIT pages: {pct}% ({(k + 1) * 2}/{num_pages} pages)...")

    # Touch final page if total page count is odd
    if (num_pages & 1) == 1 and num_pages > 1:
        last_page = rx_addr + ((num_pages - 1) << 14)
        process.WriteMemory(last_page, b"\x69", err)

    dt = time.time() - t0
    print(
        f"[Brama-Xcode-JIT] Blessed {num_pages} pages ({size_mb} MB) at RX=0x{rx_addr:x} in {dt:.2f}s — resuming Brama!"
    )

    x0_reg.SetValueFromCString(f"0x{rx_addr:x}")
    _advance_pc_past_brk(frame)
    return True


def on_jit26_prepare_region(frame, bp_loc, internal_dict):
    """LLDB breakpoint callback for `jit26_prepare_region`."""
    try:
        process = frame.GetThread().GetProcess()
        stop_key = ("prepare", process.GetProcessID(), process.GetStopID())
        if stop_key in _handled_stops:
            return False
        _handled_stops.add(stop_key)
        _prepare_txm_jit_pool(frame)
    except Exception as exc:
        print(f"[Brama-Xcode-JIT] Exception in on_jit26_prepare_region: {exc}")
    # Return False so LLDB automatically continues execution without pausing Xcode UI
    return False


def on_jit26_detach(frame, bp_loc, internal_dict):
    """LLDB breakpoint callback for `jit26_detach`."""
    try:
        process = frame.GetThread().GetProcess()
        stop_key = ("detach", process.GetProcessID(), process.GetStopID())
        if stop_key in _handled_stops:
            return False
        _handled_stops.add(stop_key)
        _configure_process_for_wine(process.GetTarget().GetDebugger(), process)
        _advance_pc_past_brk(frame)
        print("[Brama-Xcode-JIT] Intercepted jit26_detach — keeping Xcode console attached & continuing.")
    except Exception as exc:
        print(f"[Brama-Xcode-JIT] Exception in on_jit26_detach: {exc}")
    return False


def cmd_brama_jit_prepare(debugger, command, result, internal_dict):
    """Manual command `brama_jit_prepare` if already paused at `brk #0xf00d` in Xcode."""
    target = debugger.GetSelectedTarget()
    if not target or not target.IsValid():
        result.AppendMessage("[Brama-Xcode-JIT] No active target.")
        return
    process = target.GetProcess()
    if not process or not process.IsValid():
        result.AppendMessage("[Brama-Xcode-JIT] No active process.")
        return

    frame = process.GetSelectedThread().GetSelectedFrame()
    sym_name = (frame.GetSymbol().GetName() if frame.GetSymbol() else "") or ""
    if "jit26_detach" in sym_name:
        _configure_process_for_wine(debugger, process)
        _advance_pc_past_brk(frame)
        process.Continue()
        return

    _prepare_txm_jit_pool(frame)
    process.Continue()


def _install_breakpoints_on_target(ci, dummy=True):
    """Register auto-continuing breakpoints for `jit26_prepare_region` and `jit26_detach`."""
    res = lldb.SBCommandReturnObject()
    flag = "-D " if dummy else ""

    ci.HandleCommand(f"breakpoint delete {flag}brama_jit26_prepare", res)
    ci.HandleCommand(f"breakpoint delete {flag}brama_jit26_detach", res)

    ci.HandleCommand(f"breakpoint set {flag}-K false -n jit26_prepare_region -N brama_jit26_prepare", res)
    ci.HandleCommand(
        f"breakpoint command add {flag}-F xcode_jit_bridge.on_jit26_prepare_region brama_jit26_prepare",
        res,
    )

    ci.HandleCommand(f"breakpoint set {flag}-K false -n jit26_detach -N brama_jit26_detach", res)
    ci.HandleCommand(
        f"breakpoint command add {flag}-F xcode_jit_bridge.on_jit26_detach brama_jit26_detach",
        res,
    )


def __lldb_init_module(debugger, internal_dict):
    ci = debugger.GetCommandInterpreter()
    res = lldb.SBCommandReturnObject()

    ci.HandleCommand(
        "command script add -f xcode_jit_bridge.cmd_brama_jit_prepare brama_jit_prepare",
        res,
    )

    # Install on LLDB's dummy target so all future targets created by Xcode inherit the breakpoints
    _install_breakpoints_on_target(ci, dummy=True)

    # Also install on any currently selected target
    if debugger.GetNumTargets() > 0:
        _install_breakpoints_on_target(ci, dummy=False)

    print("[Brama-Xcode-JIT] Armed automatic iOS 26 TXM JIT bridge (jit26_prepare_region & jit26_detach).")
