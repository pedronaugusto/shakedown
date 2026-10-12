const std = @import("std");
pub const zig_version = std.SemanticVersion.parse(zig_version_string) catch unreachable;
pub const zig_version_string = "0.17.0";
pub const zig_backend = std.lang.CompilerBackend.stage2_llvm;

pub const output_mode: std.lang.OutputMode = .Exe;
pub const link_mode: std.lang.LinkMode = .dynamic;
pub const unwind_tables: std.lang.UnwindTables = .async;
pub const is_test = false;
pub const single_threaded = true;
/// Deprecated; to be removed in 0.18.0. Use `target.abi` instead.
pub const abi: std.Target.Abi = .none;
/// Deprecated; to be removed in 0.18.0. Use `target.cpu` instead.
pub const cpu: std.Target.Cpu = .{
    .arch = .aarch64,
    .model = &std.Target.aarch64.cpu.apple_m3,
    .features = std.Target.aarch64.featureSet(&.{
        .aes,
        .alternate_sextload_cvt_f32_pattern,
        .altnzcv,
        .am,
        .amvs,
        .arith_bcc_fusion,
        .arith_cbz_fusion,
        .bf16,
        .bti,
        .ccdp,
        .ccidx,
        .ccpp,
        .complxnum,
        .contextidr_el2,
        .crc,
        .disable_latency_sched_heuristic,
        .dit,
        .dotprod,
        .ecv,
        .el2vmsa,
        .el3,
        .fgt,
        .flagm,
        .fp16fml,
        .fp_armv8,
        .fpac,
        .fptoint,
        .fullfp16,
        .fuse_address,
        .fuse_adrp_add,
        .fuse_aes,
        .fuse_arith_logic,
        .fuse_crypto_eor,
        .fuse_csel,
        .fuse_literals,
        .hcx,
        .i8mm,
        .jsconv,
        .lor,
        .lse,
        .lse2,
        .max_interleave_factor_4,
        .mpam,
        .neon,
        .no_zcz_fpr64,
        .nv,
        .pan,
        .pan_rwv,
        .pauth,
        .perfmon,
        .predres,
        .ras,
        .rcpc,
        .rcpc_immo,
        .rdm,
        .sb,
        .sel2,
        .sha2,
        .sha3,
        .specrestrict,
        .ssbs,
        .store_pair_suppress,
        .tlb_rmi,
        .tracev8_4,
        .uaops,
        .v8_1a,
        .v8_2a,
        .v8_3a,
        .v8_4a,
        .v8_5a,
        .v8_6a,
        .v8a,
        .vh,
        .zcm_fpr128,
        .zcm_gpr64,
        .zcz_fpr128,
        .zcz_gpr32,
        .zcz_gpr64,
    }),
};
/// Deprecated; to be removed in 0.18.0. Use `target.os` instead.
pub const os: std.Target.Os = .{
    .tag = .macos,
    .version_range = .{ .semver = .{
        .min = .{
            .major = 26,
            .minor = 2,
            .patch = 0,
        },
        .max = .{
            .major = 26,
            .minor = 2,
            .patch = 0,
        },
    }},
};
pub const target: std.Target = .{
    .cpu = cpu,
    .os = os,
    .abi = abi,
    .ofmt = object_format,
    .dynamic_linker = .init("/usr/lib/dyld"),
};
/// Deprecated; to be removed in 0.18.0. Use `target.ofmt` instead.
pub const object_format: std.Target.ObjectFormat = .macho;
/// Deprecated, to be removed after 0.18.0
pub const mode = optimize;
pub const optimize: std.lang.Optimize = .debug;
pub const link_libc = true;
pub const link_libcpp = false;
pub const have_error_return_tracing = true;
pub const valgrind_support = false;
pub const sanitize_thread = false;
pub const fuzz = false;
pub const position_independent_code = true;
pub const position_independent_executable = true;
pub const strip_debug_info = false;
pub const code_model: std.lang.CodeModel = .default;
pub const omit_frame_pointer = false;
