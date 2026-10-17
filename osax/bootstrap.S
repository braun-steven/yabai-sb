// Relocatable arm64e template copied into Dock. Literal slots are patched in a writable local copy.
// The Mach bootstrap can only create a pthread; dlopen and pthread_exit run on that pthread.
.section __TEXT,__const
.p2align 3
.globl _sa_bootstrap_start, _sa_bootstrap_end
.globl _sa_bootstrap_create, _sa_bootstrap_open, _sa_bootstrap_exit
.globl _sa_bootstrap_threadid, _sa_bootstrap_context, _sa_bootstrap_path
_sa_bootstrap_start:
    sub sp, sp, #32
    add x0, sp, #16
    mov x1, xzr
    adr x2, worker
    paciza x2
    ldr x3, _sa_bootstrap_context
    ldr x9, _sa_bootstrap_create
    blr x9
    ldr x9, _sa_bootstrap_context
    str w0, [x9]
    movz x0, #0x6265
    movk x0, #0x7961, lsl #16
bootstrap_wait:
    b bootstrap_wait
worker:
    pacibsp
    stp x19, x30, [sp, #-16]!
    mov x19, x0
    mov x0, xzr
    add x1, x19, #16
    ldr x9, _sa_bootstrap_threadid
    blr x9
    adr x0, _sa_bootstrap_path
    mov x1, #2 // RTLD_NOW
    ldr x9, _sa_bootstrap_open
    blr x9
    str x0, [x19, #8]
    add x10, x19, #4
    mov w9, #1
    stlr w9, [x10]
    mov x0, xzr
    ldp x19, x30, [sp], #16
    autibsp
    // No return into this allocation. The loader still waits until this thread has disappeared
    // before deallocating either code or context; seeing the completion flag alone is insufficient.
    ldr x9, _sa_bootstrap_exit
    br x9
.p2align 3
_sa_bootstrap_create: .quad 0
_sa_bootstrap_open: .quad 0
_sa_bootstrap_exit: .quad 0
_sa_bootstrap_threadid: .quad 0
_sa_bootstrap_context: .quad 0
_sa_bootstrap_path: .space 256
_sa_bootstrap_end:
