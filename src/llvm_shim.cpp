// RGC LLVM backend shim: compiles LLVM IR to an object file in-process.
// stage1 calls it via the compiler builtin emit_object(); no clang/llc dependency.

#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Target/TargetOptions.h"
#include "llvm/TargetParser/Host.h"
#include "llvm/TargetParser/Triple.h"

#include <cstdlib>
#include <memory>
#include <string>

extern "C" int rgc_emit_object(const char* ir_text, const char* obj_path) {
    if (!ir_text || !obj_path) {
        return 1;
    }
    // Initialize the target matching the host LLVM build (X86 on x64,
    // AArch64 on Windows/macOS/Linux arm64).
    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmParser();
    llvm::InitializeNativeTargetAsmPrinter();

    llvm::LLVMContext ctx;
    llvm::SMDiagnostic parseErr;
    std::unique_ptr<llvm::Module> module =
        llvm::parseAssemblyString(ir_text, parseErr, ctx);
    if (!module) {
        if (std::getenv("RGC_DEBUG_CODEGEN")) {
            parseErr.print("rgc", llvm::errs());
        }
        return 1;
    }

    llvm::Triple triple(llvm::sys::getDefaultTargetTriple());
    module->setTargetTriple(triple);

    // Read the compile options: ir.rg writes {opt_level, debug_info} into the !rgc.options named metadata,
    // defaulting to release (O2). With opt_level=0 no module-level optimization runs and the backend uses the None level;
    // debug_info only affects whether the IR carries DI metadata; DWARF is generated automatically by the backend.
    int opt_level = 2;
    if (llvm::NamedMDNode* nm = module->getNamedMetadata("rgc.options")) {
        if (nm->getNumOperands() > 0) {
            if (auto* tup = llvm::dyn_cast<llvm::MDNode>(nm->getOperand(0))) {
                if (tup->getNumOperands() >= 1) {
                    if (auto* c = llvm::mdconst::extract_or_null<llvm::ConstantInt>(
                            tup->getOperand(0))) {
                        opt_level = static_cast<int>(c->getSExtValue());
                    }
                }
            }
        }
    }

    std::string error;
    const llvm::Target* target = llvm::TargetRegistry::lookupTarget(triple, error);
    if (!target) {
        if (std::getenv("RGC_DEBUG_CODEGEN")) {
            llvm::errs() << "rgc: cannot initialize target: " << error << "\n";
        }
        return 1;
    }
    std::unique_ptr<llvm::TargetMachine> tm(target->createTargetMachine(
        triple, "generic", "", llvm::TargetOptions(), llvm::Reloc::PIC_,
        std::nullopt,
        opt_level == 0 ? llvm::CodeGenOptLevel::None
                       : llvm::CodeGenOptLevel::Default));
    if (!tm) {
        return 1;
    }
    module->setDataLayout(tm->createDataLayout());

    llvm::LoopAnalysisManager lam;
    llvm::FunctionAnalysisManager fam;
    llvm::CGSCCAnalysisManager cgam;
    llvm::ModuleAnalysisManager mam;
    llvm::PassBuilder pb(tm.get());
    fam.registerPass([&] { return pb.buildDefaultAAPipeline(); });
    pb.registerModuleAnalyses(mam);
    pb.registerCGSCCAnalyses(cgam);
    pb.registerFunctionAnalyses(fam);
    pb.registerLoopAnalyses(lam);
    pb.crossRegisterProxies(lam, fam, cgam, mam);
    llvm::ModulePassManager mpm;
    if (opt_level > 0) {
        mpm = pb.buildPerModuleDefaultPipeline(llvm::OptimizationLevel::O2);
        mpm.run(*module, mam);
    }

    std::string verifyErr;
    llvm::raw_string_ostream verifyStream(verifyErr);
    if (llvm::verifyModule(*module, &verifyStream)) {
        verifyStream.flush();
        if (std::getenv("RGC_DEBUG_CODEGEN")) {
            llvm::errs() << "rgc: module verification failed\n" << verifyErr << "\n";
            module->print(llvm::errs(), nullptr);
        }
        return 1;
    }

    std::error_code ec;
    llvm::raw_fd_ostream dest(obj_path, ec, llvm::sys::fs::OF_None);
    if (ec) {
        return 1;
    }
    llvm::legacy::PassManager pass;
    if (tm->addPassesToEmitFile(pass, dest, nullptr,
                                llvm::CodeGenFileType::ObjectFile)) {
        return 1;
    }
    pass.run(*module);
    dest.flush();
    return 0;
}
