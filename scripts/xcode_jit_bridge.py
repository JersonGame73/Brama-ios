#!/usr/bin/env python3
"""
Brama — Xcode / LLDB iOS 26 TXM JIT Bridge for Madeira (Wine 9.0 ARM64EC + FEX-Emu)
===================================================================================
Automatically intercepts `jit26_prepare_region` and `jit26_detach` when running Brama
from Xcode (`Cmd + R`) on iOS / iPadOS 26+ devices with TXM (Trusted Execution Monitor).
"""

import sys
import time
import lldb

_handled_stops = set()
_configured_pids = set()


def _log(debugger, result, msg):
    line = f"{msg}\n"
    if result is not None:
        result.AppendMessage(msg)
    try:
        if debugger and debugger.IsValid():
            stream = debugger.GetAsyncOutputStream()
            if stream and stream.IsValid():
                stream.Write(line)
                stream.Flush()
    except Exception:
        pass
    sys.stdout.write(line)
    sys.stdout.flush()


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


def _find_target_frame(process, target_symbol_substring):
    """Find the thread and frame stopped in `target_symbol_substring` (or fallback to selected thread)."""
    for i in range(process.GetNumThreads()):
        t = process.GetThreadAtIndex(i)
        f = t.GetFrameAtIndex(0)
        if f and f.IsValid():
            sym = f.GetSymbol()
            name = (sym.GetName() if sym and sym.IsValid() else "") or (f.GetFunctionName() or "")
            if target_symbol_substring in name:
                process.SetSelectedThread(t)
                return f
    return process.GetSelectedThread().GetSelectedFrame()


def _advance_pc_past_brk(frame):
    """Advance PC past `brk #0xf00d` inside `jit26_prepare_region` or `jit26_detach`."""
    pc_reg = frame.FindRegister("pc")
    lr_reg = frame.FindRegister("lr")
    pc = pc_reg.GetValueAsUnsigned(0)
    lr = lr_reg.GetValueAsUnsigned(0) if lr_reg and lr_reg.IsValid() else 0

    new_pc = 0
    sym = frame.GetSymbol()
    if sym and sym.IsValid():
        target = frame.GetThread().GetProcess().GetTarget()
        func_start = sym.GetStartAddress().GetLoadAddress(target)
        func_name = sym.GetName() or ""
        if "jit26_prepare_region" in func_name and func_start != lldb.LLDB_INVALID_ADDRESS:
            # _jit26_prepare_region in libmadeira.dylib:
            #   +0x00: sub sp, sp, #0x20
            #   ...
            #   +0x28: brk #0xf00d
            #   +0x2c: str x0, [sp, #0x8]
            #   +0x30: ldr x0, [sp, #0x8]
            #   +0x34: add sp, sp, #0x20
            #   +0x38: ret
            if pc == func_start and lr != 0:
                new_pc = lr
            elif pc > func_start:
                new_pc = func_start + 0x2c

    if new_pc == 0:
        new_pc = lr if lr != 0 else (pc + 4)

    frame.SetPC(new_pc)
    if pc_reg and pc_reg.IsValid():
        pc_reg.SetValueFromCString(f"0x{new_pc:x}")


def _prepare_txm_jit_pool(debugger, frame, result=None):
    """Allocate and TXM-bless the requested RX JIT pool in debugserver."""
    thread = frame.GetThread()
    process = thread.GetProcess()

    _configure_process_for_wine(debugger, process)

    x0_reg = frame.FindRegister("x0")
    x1_reg = frame.FindRegister("x1")
    req_addr = x0_reg.GetValueAsUnsigned(0) if x0_reg and x0_reg.IsValid() else 0
    req_size = x1_reg.GetValueAsUnsigned(0) if x1_reg and x1_reg.IsValid() else 0

    if req_size == 0 or req_size > 0x40000000:
        req_size = 0x8000000  # Default: 128 MB

    size_mb = req_size // (1024 * 1024)
    _log(
        debugger,
        result,
        f"[Brama-Xcode-JIT] Intercepted jit26_prepare_region(addr=0x{req_addr:x}, size=0x{req_size:x} [{size_mb} MB])",
    )

    err = lldb.SBError()
    rx_addr = process.AllocateMemory(
        req_size, lldb.ePermissionsReadable | lldb.ePermissionsExecutable, err
    )
    if not err.Success() or rx_addr == lldb.LLDB_INVALID_ADDRESS or rx_addr == 0:
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
        _log(debugger, result, f"[Brama-Xcode-JIT] ERROR: Failed to allocate RX region of {size_mb} MB: {err}")
        if x0_reg and x0_reg.IsValid():
            x0_reg.SetValueFromCString("0x0")
        _advance_pc_past_brk(frame)
        return False

    page_size = 0x4000  # 16 KB Apple Silicon page size
    num_pages = (req_size + page_size - 1) // page_size
    t0 = time.time()
    _log(
        debugger,
        result,
        f"[Brama-Xcode-JIT] Allocated RX @ 0x{rx_addr:x} ({size_mb} MB, {num_pages} pages). Blessing TXM pages...",
    )

    # Touch first page
    process.WriteMemory(rx_addr, b"\x69", err)

    # Write 2 bytes (0x69 0x69) across each odd 16KB page boundary:
    # Each call faults and TXM-blesses TWO adjacent 16KB pages simultaneously.
    pair_count = num_pages // 2
    two_bytes = b"\x69\x69"
    step_report = max(1, pair_count // 4)
    for k in range(pair_count):
        boundary = rx_addr + (((2 * k + 1) << 14) - 1)
        process.WriteMemory(boundary, two_bytes, err)
        if (k + 1) % step_report == 0:
            pct = int(((k + 1) * 100) / pair_count)
            _log(
                debugger,
                result,
                f"[Brama-Xcode-JIT] Blessing TXM JIT pages: {pct}% ({(k + 1) * 2}/{num_pages} pages)...",
            )

    if (num_pages & 1) == 1 and num_pages > 1:
        last_page = rx_addr + ((num_pages - 1) << 14)
        process.WriteMemory(last_page, b"\x69", err)

    dt = time.time() - t0
    _log(
        debugger,
        result,
        f"[Brama-Xcode-JIT] Blessed {num_pages} pages ({size_mb} MB) at RX=0x{rx_addr:x} in {dt:.2f}s — resuming Brama!",
    )

    if x0_reg and x0_reg.IsValid():
        x0_reg.SetValueFromCString(f"0x{rx_addr:x}")
    _advance_pc_past_brk(frame)
    return True


def on_jit26_prepare_region(frame, bp_loc, internal_dict):
    """LLDB Python breakpoint callback for `jit26_prepare_region`."""
    try:
        process = frame.GetThread().GetProcess()
        debugger = process.GetTarget().GetDebugger()
        stop_key = ("prepare", process.GetProcessID(), process.GetStopID())
        if stop_key in _handled_stops:
            return False
        _handled_stops.add(stop_key)
        _prepare_txm_jit_pool(debugger, frame, None)
    except Exception as exc:
        sys.stdout.write(f"[Brama-Xcode-JIT] Exception in on_jit26_prepare_region: {exc}\n")
        sys.stdout.flush()
    return False


def on_jit26_detach(frame, bp_loc, internal_dict):
    """LLDB Python breakpoint callback for `jit26_detach`."""
    try:
        process = frame.GetThread().GetProcess()
        debugger = process.GetTarget().GetDebugger()
        stop_key = ("detach", process.GetProcessID(), process.GetStopID())
        if stop_key in _handled_stops:
            return False
        _handled_stops.add(stop_key)
        _configure_process_for_wine(debugger, process)
        _advance_pc_past_brk(frame)
        _log(debugger, None, "[Brama-Xcode-JIT] Intercepted jit26_detach — keeping Xcode console attached & continuing.")
    except Exception as exc:
        sys.stdout.write(f"[Brama-Xcode-JIT] Exception in on_jit26_detach: {exc}\n")
        sys.stdout.flush()
    return False


def cmd_brama_jit_prepare(debugger, command, result, internal_dict):
    """LLDB command `brama_jit_prepare` (can be called manually from `(lldb)` or from a breakpoint)."""
    target = debugger.GetSelectedTarget()
    if not target or not target.IsValid():
        _log(debugger, result, "[Brama-Xcode-JIT] No active target.")
        return
    process = target.GetProcess()
    if not process or not process.IsValid():
        _log(debugger, result, "[Brama-Xcode-JIT] No active process.")
        return

    is_auto = "--auto" in (command or "")
    frame = _find_target_frame(process, "jit26_")
    sym_name = (frame.GetSymbol().GetName() if frame and frame.GetSymbol() else "") or ""

    if "jit26_detach" in sym_name:
        stop_key = ("detach", process.GetProcessID(), process.GetStopID())
        if stop_key not in _handled_stops:
            _handled_stops.add(stop_key)
            _configure_process_for_wine(debugger, process)
            _advance_pc_past_brk(frame)
            _log(debugger, result, "[Brama-Xcode-JIT] Intercepted jit26_detach — continuing.")
        if not is_auto:
            process.Continue()
        return

    stop_key = ("prepare", process.GetProcessID(), process.GetStopID())
    if stop_key not in _handled_stops:
        _handled_stops.add(stop_key)
        _prepare_txm_jit_pool(debugger, frame, result)
    if not is_auto:
        process.Continue()


def _has_named_breakpoint(target, bp_name):
    if not target or not target.IsValid():
        return False
    names = lldb.SBStringList()
    for i in range(target.GetNumBreakpoints()):
        bp = target.GetBreakpointAtIndex(i)
        names.Clear()
        bp.GetNames(names)
        for j in range(names.GetSize()):
            if names.GetStringAtIndex(j) == bp_name:
                return True
    return False


def _install_breakpoints_on_target(debugger, ci, dummy=True):
    """Register auto-continuing breakpoints for `jit26_prepare_region` and `jit26_detach`."""
    res = lldb.SBCommandReturnObject()
    if dummy:
        ci.HandleCommand("breakpoint delete -D brama_jit26_prepare", res)
        ci.HandleCommand("breakpoint delete -D brama_jit26_detach", res)
        ci.HandleCommand(
            "breakpoint set -D -G true -K false -n jit26_prepare_region -N brama_jit26_prepare",
            res,
        )
        ci.HandleCommand(
            'breakpoint command add -D -o "brama_jit_prepare --auto" brama_jit26_prepare',
            res,
        )
        ci.HandleCommand(
            "breakpoint set -D -G true -K false -n jit26_detach -N brama_jit26_detach",
            res,
        )
        ci.HandleCommand(
            'breakpoint command add -D -o "brama_jit_prepare --auto" brama_jit26_detach',
            res,
        )
    else:
        target = debugger.GetSelectedTarget()
        if not _has_named_breakpoint(target, "brama_jit26_prepare"):
            ci.HandleCommand(
                "breakpoint set -G true -K false -n jit26_prepare_region -N brama_jit26_prepare",
                res,
            )
            ci.HandleCommand(
                'breakpoint command add -o "brama_jit_prepare --auto" brama_jit26_prepare',
                res,
            )
        if not _has_named_breakpoint(target, "brama_jit26_detach"):
            ci.HandleCommand(
                "breakpoint set -G true -K false -n jit26_detach -N brama_jit26_detach",
                res,
            )
            ci.HandleCommand(
                'breakpoint command add -o "brama_jit_prepare --auto" brama_jit26_detach',
                res,
            )


def __lldb_init_module(debugger, internal_dict):
    ci = debugger.GetCommandInterpreter()
    res = lldb.SBCommandReturnObject()

    ci.HandleCommand(
        "command script add -o -f xcode_jit_bridge.cmd_brama_jit_prepare brama_jit_prepare",
        res,
    )

    _install_breakpoints_on_target(debugger, ci, dummy=True)

    if debugger.GetNumTargets() > 0:
        _install_breakpoints_on_target(debugger, ci, dummy=False)

    print("[Brama-Xcode-JIT] Armed automatic iOS 26 TXM JIT bridge (jit26_prepare_region & jit26_detach).")
